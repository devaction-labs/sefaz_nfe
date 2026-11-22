defmodule SefazNfe.CircuitBreaker do
  @moduledoc """
  One breaker per UF, so a SEFAZ that is down cannot drag the others with it.

  A UF whose authorizer is unreachable would otherwise cost every caller a full
  timeout, and enough of those in flight exhausts the pool that other UFs also
  need. After `:threshold` consecutive transport failures the breaker opens and
  calls to that UF fail immediately with `{:error, {:circuit_open, uf}}`; after
  `:cooldown` one call is let through, and it either closes the breaker or
  re-opens it.

  ## What counts as a failure

  Transport only — timeouts, TLS alerts, unreachable hosts, HTTP 5xx. A SEFAZ
  rejection is a business answer that arrived successfully, so `cStat` 204 or
  656 leaves the breaker closed. Tripping on rejections would take a UF offline
  for a caller sending bad documents.

  ## Telemetry

  `[:sefaz_nfe, :circuit_breaker, :open | :close | :rejected]`, with `%{uf: uf}`;
  see `SefazNfe.Telemetry`. They fire on the transition itself. The breaker is
  not linearised, so racing failures at the threshold may emit `:open` twice.

  ## Why ETS rather than a process

  The check runs on every request. A GenServer per UF would serialise exactly
  the traffic this is meant to protect; the table is read directly and updated
  with atomic counters, so a healthy UF pays one lookup.
  """

  use GenServer

  @table __MODULE__
  @default_threshold 5
  @default_cooldown Duration.new!(second: 30)

  @type key :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    {:ok, %{}}
  end

  @doc """
  Whether a call to `uf` may proceed.

  A breaker past its cooldown is let through as a trial: the next
  `record_success/1` closes it, and the next `record_failure/1` re-opens it for
  another cooldown.
  """
  @spec check(key()) :: :ok | {:error, {:circuit_open, key()}}
  def check(uf) do
    case :ets.lookup(@table, uf) do
      [] -> :ok
      [{^uf, _failures, nil}] -> :ok
      [{^uf, _failures, opened_at}] -> trial(uf, opened_at)
    end
  rescue
    ArgumentError -> :ok
  end

  defp trial(uf, opened_at) do
    if System.monotonic_time(:millisecond) - opened_at >= to_timeout(cooldown()) do
      :ok
    else
      emit(:rejected, uf)
      {:error, {:circuit_open, uf}}
    end
  end

  @doc "Records a call that reached SEFAZ, closing the breaker."
  @spec record_success(key()) :: :ok
  def record_success(uf) do
    # `take/2` is atomic, so of several racing successes one sees the open entry.
    case :ets.take(@table, uf) do
      [{^uf, _failures, opened_at}] when opened_at != nil -> emit(:close, uf)
      _closed_or_counting -> :ok
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Records a transport failure, opening the breaker at the threshold."
  @spec record_failure(key()) :: :ok
  def record_failure(uf) do
    failures = :ets.update_counter(@table, uf, {2, 1}, {uf, 0, nil})

    if failures >= threshold(), do: trip(uf)

    :ok
  rescue
    ArgumentError -> :ok
  end

  # An event only when this is a transition: no `opened_at` yet, or one past its
  # cooldown (a failed trial). A failure that lands while the breaker is already
  # open only extends it. The read and the write are not one atomic step, so two
  # racing failures can both emit `:open`; that is documented, not prevented.
  defp trip(uf) do
    now = System.monotonic_time(:millisecond)

    transition? =
      case :ets.lookup(@table, uf) do
        [{^uf, _failures, opened_at}] when is_integer(opened_at) ->
          now - opened_at >= to_timeout(cooldown())

        _not_open ->
          true
      end

    :ets.update_element(@table, uf, {3, now})
    if transition?, do: emit(:open, uf)
  end

  defp emit(:rejected, uf) do
    :telemetry.execute([:sefaz_nfe, :circuit_breaker, :rejected], %{count: 1}, %{uf: uf})
  end

  defp emit(event, uf) do
    :telemetry.execute(
      [:sefaz_nfe, :circuit_breaker, event],
      %{count: 1, system_time: System.system_time()},
      %{uf: uf}
    )
  end

  @doc "Forgets every breaker. For tests and for an operator forcing a retry."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp threshold, do: Application.get_env(:sefaz_nfe, :circuit_threshold, @default_threshold)
  defp cooldown, do: Application.get_env(:sefaz_nfe, :circuit_cooldown, @default_cooldown)
end
