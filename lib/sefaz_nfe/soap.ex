defmodule SefazNfe.SOAP do
  @moduledoc """
  HTTP+mTLS POST of a SOAP envelope.

  A behaviour, so a host can substitute its own transport and so `mix test`
  never opens a socket. `SefazNfe.SOAP.HTTPC` is the default implementation.
  """

  alias SefazNfe.CircuitBreaker

  @type cert :: SefazNfe.Certificate.t()

  @callback call(String.t(), iodata(), cert(), keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  The configured client, defaulting to the real mTLS one.

  The default is deliberately the working client: a host that installs this
  library should be able to call SEFAZ without extra configuration. The test
  suite swaps it for `SefazNfe.SOAP.NotImplemented` in `config/test.exs`, which
  is what keeps `mix test` off the network.
  """
  @spec client() :: module()
  def client do
    Application.get_env(:sefaz_nfe, :soap, SefazNfe.SOAP.HTTPC)
  end

  @doc """
  Runs `c:call/4` in `SefazNfe.TaskSupervisor` so an SSL/SOAP abort
  does not take down the caller (Jurić: I/O failure domain).

  Emits `[:sefaz_nfe, :soap, :start | :stop | :exception]` (SEFAZ-14). The
  `:uf` option is consumed here as telemetry metadata; every other option,
  `:timeout` included, is forwarded to `c:call/4`. The timeout has to reach the
  client: it governs the request, and supervising a task for longer than the
  request it contains would let the option shorten a call and never lengthen
  one. Metadata never carries the
  certificate, the password or the XML body — only the endpoint, the UF, the
  service and an outcome tag. That tag is deliberately low cardinality: the raw
  reason would drag a whole `{:soap_crash, stacktrace}` into every metrics
  label.

  Calls are gated by `SefazNfe.CircuitBreaker` on `:uf`, so a UF that stops
  answering fails fast instead of costing every caller a full timeout.
  """
  @spec isolated_call(String.t(), iodata(), cert(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def isolated_call(endpoint, body, cert, opts \\ []) do
    {timeout, opts} = Keyword.pop_lazy(opts, :timeout, fn -> to_timeout(second: 30) end)
    {meta, rest} = Keyword.split(opts, [:uf, :service])
    task_opts = Keyword.take(meta, [:service]) ++ rest ++ [timeout: timeout]
    metadata = meta |> Map.new() |> Map.put(:endpoint, endpoint)
    uf = Keyword.get(meta, :uf, "")

    with :ok <- CircuitBreaker.check(uf) do
      :telemetry.span([:sefaz_nfe, :soap], metadata, fn ->
        result = run(endpoint, body, cert, task_opts, timeout)
        record(uf, result)
        {result, Map.put(metadata, :outcome, outcome(result))}
      end)
    end
  end

  # A reply that reached us — even a SOAP fault or an HTTP 4xx — proves the UF
  # is answering. Only the transport failures below say otherwise.
  defp record(uf, {:error, reason}) when reason in [:timeout, :unreachable] do
    CircuitBreaker.record_failure(uf)
  end

  defp record(uf, {:error, {:tls, _alert}}), do: CircuitBreaker.record_failure(uf)
  defp record(uf, {:error, {:tls, _alert, _detail}}), do: CircuitBreaker.record_failure(uf)
  defp record(uf, {:error, {:dns, _reason}}), do: CircuitBreaker.record_failure(uf)
  defp record(uf, {:error, {:soap_crash, _reason}}), do: CircuitBreaker.record_failure(uf)

  defp record(uf, {:error, {:http, status, _body}}) when status >= 500 do
    CircuitBreaker.record_failure(uf)
  end

  defp record(uf, _reached_sefaz), do: CircuitBreaker.record_success(uf)

  # The task waits a little longer than the request it supervises, so a request
  # that times out is reported by the client — which knows it was a request
  # timeout — instead of being killed a moment earlier by the supervisor, which
  # would only know that something took too long. Without the grace the two
  # deadlines are identical and the race decides which error the caller sees.
  @grace to_timeout(second: 5)

  defp run(endpoint, body, cert, task_opts, timeout) do
    task =
      Task.Supervisor.async_nolink(SefazNfe.TaskSupervisor, fn ->
        client().call(endpoint, body, cert, task_opts)
      end)

    case Task.yield(task, timeout + @grace) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:soap_crash, reason}}
    end
  end

  defp outcome({:ok, _body}), do: :ok
  defp outcome({:error, reason}) when is_atom(reason), do: reason
  defp outcome({:error, {tag, _detail}}) when is_atom(tag), do: tag
  defp outcome({:error, {tag, _detail, _more}}) when is_atom(tag), do: tag
  defp outcome({:error, _reason}), do: :error

  defmodule NotImplemented do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(_endpoint, _body, _cert, _opts), do: {:error, :not_implemented}
  end
end
