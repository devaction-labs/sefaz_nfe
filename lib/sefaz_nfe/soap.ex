defmodule SefazNfe.SOAP do
  @moduledoc """
  HTTP+mTLS POST of a SOAP envelope.

  A behaviour, so a host can substitute its own transport and so `mix test`
  never opens a socket. `SefazNfe.SOAP.HTTPC` is the default implementation.

  ## Telemetry timing

  The `[:sefaz_nfe, :soap]` span measures the total duration of the request
  only. `:httpc` exposes no per-phase timing (connect, transmit, response), and
  measuring them separately would mean opening the TLS connection outside
  `:httpc`, which changes behaviour; the default transport therefore does not
  split them. A custom `SefazNfe.SOAP` client that can see the phases may emit
  finer events of its own.
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
  `:uf`, `:environment`, `:model` and `:contingency` options are consumed here
  as telemetry metadata, with `:service` (see `SefazNfe.Telemetry`); every other option,
  `:timeout` and `:connect_timeout` included, is forwarded to `c:call/4`: they
  govern the request, and the task window follows them rather than the other way
  round. Metadata never carries the certificate, the password or the XML body —
  only the endpoint, the UF, the service and an outcome tag. That tag is deliberately low cardinality: the raw
  reason would drag a whole `{:soap_crash, stacktrace}` into every metrics
  label.

  Calls are gated by `SefazNfe.CircuitBreaker` keyed by the endpoint's host
  (`https://host:port`, lower case), the server actually called: a server that
  stops answering fails fast instead of costing every caller a full timeout,
  without touching other models of the same UF or other UFs on other servers.
  The key is also the `:host` metadata of the span.
  """
  @spec isolated_call(String.t(), iodata(), cert(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def isolated_call(endpoint, body, cert, opts \\ []) do
    {timeout, opts} = Keyword.pop_lazy(opts, :timeout, fn -> to_timeout(second: 30) end)
    {meta, rest} = Keyword.split(opts, [:uf, :service, :environment, :model, :contingency])
    task_opts = Keyword.take(meta, [:service]) ++ rest ++ [timeout: timeout]
    deadline = max(timeout, Keyword.get(rest, :connect_timeout, 0))

    host = host_key(endpoint)

    metadata =
      %{environment: nil, model: nil, contingency: nil}
      |> Map.merge(Map.new(meta))
      |> Map.put(:endpoint, endpoint)
      |> Map.put(:host, host)

    with :ok <- CircuitBreaker.check(host) do
      :telemetry.span([:sefaz_nfe, :soap], metadata, fn ->
        result = run(endpoint, body, cert, task_opts, deadline)
        record(host, result)
        {result, Map.put(metadata, :outcome, outcome(result))}
      end)
    end
  end

  # Scheme + host + port, lower-cased: one key per server, whatever the path.
  # An endpoint that does not parse into a host keeps its whole lower-cased text.
  defp host_key(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        String.downcase("#{scheme}://#{host}:#{port}")

      _no_host ->
        String.downcase(endpoint)
    end
  end

  # A reply that reached us — even a SOAP fault or an HTTP 4xx — proves the server
  # is answering. Only the transport failures below say otherwise.
  defp record(host, {:error, reason}) when reason in [:timeout, :unreachable] do
    CircuitBreaker.record_failure(host)
  end

  defp record(host, {:error, {:tls, _alert}}), do: CircuitBreaker.record_failure(host)
  defp record(host, {:error, {:tls, _alert, _detail}}), do: CircuitBreaker.record_failure(host)
  defp record(host, {:error, {:dns, _reason}}), do: CircuitBreaker.record_failure(host)
  defp record(host, {:error, {:soap_crash, _reason}}), do: CircuitBreaker.record_failure(host)

  defp record(host, {:error, {:http, status, _body}}) when status >= 500 do
    CircuitBreaker.record_failure(host)
  end

  defp record(host, _reached_sefaz), do: CircuitBreaker.record_success(host)

  # The window is the longer of the two client deadlines plus a grace, so the
  # client reports its own timeout instead of the supervisor killing it first.
  @grace to_timeout(second: 5)

  defp run(endpoint, body, cert, task_opts, deadline) do
    task =
      Task.Supervisor.async_nolink(SefazNfe.TaskSupervisor, fn ->
        client().call(endpoint, body, cert, task_opts)
      end)

    case Task.yield(task, deadline + @grace) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:soap_crash, reason}}
    end
  end

  defp outcome(result), do: SefazNfe.Telemetry.outcome(result)

  defmodule NotImplemented do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(_endpoint, _body, _cert, _opts), do: {:error, :not_implemented}
  end
end
