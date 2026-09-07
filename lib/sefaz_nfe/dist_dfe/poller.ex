defmodule SefazNfe.DistDFe.Poller do
  @moduledoc """
  One process per tax ID (CNPJ or CPF) for `NFeDistribuicaoDFe`.

  The library does not persist `ult_nsu` — the host does (AD-002). This process
  owns the poll loop, a process label for Observer, and the hand-off of each
  page to the caller's `:handler`.

  ## Handler contract

  `:handler` is **required**: a poller with nowhere to deliver is a no-op. It is
  a one-arity function or an `t:mfa/0` (the page is prepended to the extra
  args), invoked in the poller process with a `t:SefazNfe.DistDFe.t/0` page. Its
  return value owns the cursor:

    * `{:ok, ult_nsu}` — continue from the cursor the host committed
    * `:ok` — continue from `page.ult_nsu` as returned by SEFAZ
    * `:stop` — stop the poller normally (the child is `:transient`, so the
      supervisor leaves it down)

  Delivery is **at-least-once**: the handler runs *before* the cursor moves, so
  a handler that raises crashes the poller and the supervisor restarts it at the
  cursor last given to `start_link/1`. DistDFe documents are idempotent by NSU,
  so a replay is cheaper than a silent gap.

  ## Scheduling

  The child is `:transient`, not the `:permanent` default: a handler answering
  `:stop` exits `:normal` and must stay down, while a crash still restarts at
  the last cursor.

  Three things shape the next delay. A page whose cursor still trails `maxNSU`
  has a backlog — DistDFe answers around 50 documents per call — so it drains
  after `@catch_up` instead of a whole interval. A page carrying `cStat` 656
  (consumo indevido) backs off for an hour, because the AN blocks the tax ID
  for that long and retrying sooner only renews the block. Every delay then
  gets up to 10% of jitter, always later and never earlier, so that thousands
  of pollers started by one release boot do not hit the AN in lockstep.

  A transport error keeps the cursor and simply waits for the next tick; the
  library never retries DistDFe in a tight loop.

  ## Logging

  A multi-tenant host polls third-party tax IDs and DistDFe accepts CPF, so a
  raw identifier in a log line is personal data piling up (LGPD). Failures name
  the poller by the last four characters only, which is enough to tell two
  apart during an incident.

  ## Options

    * `:tax_id` (required) — CNPJ (14) or CPF (11) of the interested party
    * `:cert` (required) — `t:SefazNfe.Certificate.t/0`
    * `:handler` (required) — see above
    * `:environment` — `:homologation` (default) or `:production`
    * `:ult_nsu` — starting cursor, default `"0"`
    * `:interval` — `t:Duration.t/0` between polls, default 5 minutes
    * `:fetch` — one-arity fetch function, default `&SefazNfe.dist_dfe/1`. The
      seam that keeps `mix test` off the network, and the hook for a host that
      wraps the call in its own circuit breaker.
  """

  use GenServer, restart: :transient
  require Logger

  @default_interval Duration.new!(minute: 5)

  @catch_up Duration.new!(second: 5)

  @consumo_indevido Duration.new!(hour: 1)

  @jitter 10

  @type page :: SefazNfe.DistDFe.t()
  @type handler :: (page() -> {:ok, String.t()} | :ok | :stop) | mfa()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    tax_id = Keyword.fetch!(opts, :tax_id)
    GenServer.start_link(__MODULE__, opts, name: via(tax_id))
  end

  @spec via(String.t()) :: {:via, module(), term()}
  def via(tax_id) when is_binary(tax_id) do
    {:via, Registry, {SefazNfe.Registry, {:dist_dfe, tax_id}}}
  end

  @impl true
  def init(opts) do
    tax_id = Keyword.fetch!(opts, :tax_id)
    Process.set_label({:sefaz_nfe, :dist_dfe, tax_id})

    state = %{
      tax_id: tax_id,
      cert: Keyword.fetch!(opts, :cert),
      handler: validate_handler!(Keyword.fetch!(opts, :handler)),
      fetch: Keyword.get(opts, :fetch, &SefazNfe.dist_dfe/1),
      environment: Keyword.get(opts, :environment, :homologation),
      ult_nsu: Keyword.get(opts, :ult_nsu, "0"),
      interval: Keyword.get(opts, :interval, @default_interval)
    }

    {:ok, schedule(state, state.interval)}
  end

  @impl true
  def handle_info(:poll, state) do
    %{
      tax_id: state.tax_id,
      cert: state.cert,
      environment: state.environment,
      ult_nsu: state.ult_nsu
    }
    |> state.fetch.()
    |> handle_page(state)
  end

  defp handle_page({:ok, page}, state) do
    state.handler
    |> deliver(page)
    |> commit(page, state)
  end

  defp handle_page({:error, reason}, state) do
    Logger.warning("DistDFe poll failed for #{mask(state.tax_id)}: #{inspect(reason)}")
    {:noreply, schedule(state, state.interval)}
  end

  defp mask(tax_id) do
    visible = String.slice(tax_id, -4, 4)
    String.duplicate("*", max(String.length(tax_id) - 4, 0)) <> visible
  end

  defp deliver(handler, page) when is_function(handler, 1), do: handler.(page)
  defp deliver({module, fun, args}, page), do: apply(module, fun, [page | args])

  defp commit(:stop, _page, state), do: {:stop, :normal, state}
  defp commit(:ok, page, state), do: {:noreply, advance(state, page, page.ult_nsu)}
  defp commit({:ok, cursor}, page, state), do: {:noreply, advance(state, page, cursor)}

  defp advance(state, page, cursor) when is_binary(cursor) do
    schedule(%{state | ult_nsu: cursor}, next_delay(page, state))
  end

  defp next_delay(%SefazNfe.DistDFe{c_stat: 656}, _state), do: @consumo_indevido

  defp next_delay(%SefazNfe.DistDFe{ult_nsu: ult_nsu, max_nsu: max_nsu}, state) do
    case {String.to_integer(ult_nsu), String.to_integer(max_nsu)} do
      {ult, max} when ult < max -> @catch_up
      _caught_up -> state.interval
    end
  end

  defp schedule(state, %Duration{} = delay) do
    Process.send_after(self(), :poll, jitter(to_timeout(delay)))
    state
  end

  defp jitter(timeout) when is_integer(timeout) and timeout > 0 do
    timeout + :rand.uniform(max(div(timeout, @jitter), 1))
  end

  defp validate_handler!(handler) when is_function(handler, 1), do: handler

  defp validate_handler!({module, fun, args} = handler)
       when is_atom(module) and is_atom(fun) and is_list(args),
       do: handler
end
