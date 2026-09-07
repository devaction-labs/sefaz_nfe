defmodule SefazNfe.SOAP do
  @moduledoc """
  HTTP+mTLS POST of a SOAP envelope. `mix test` must never open a socket:
  point `:sefaz_nfe, :soap` at a stub (the default is `NotImplemented`).
  """

  @type cert :: SefazNfe.Certificate.t()

  @callback call(String.t(), iodata(), cert(), keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @spec client() :: module()
  def client do
    Application.get_env(:sefaz_nfe, :soap, SefazNfe.SOAP.NotImplemented)
  end

  @doc """
  Runs `c:call/4` in `SefazNfe.TaskSupervisor` so an SSL/SOAP abort
  does not take down the caller (Jurić: I/O failure domain).
  """
  @spec isolated_call(String.t(), iodata(), cert(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def isolated_call(endpoint, body, cert, opts \\ []) do
    timeout = Keyword.get_lazy(opts, :timeout, fn -> to_timeout(second: 30) end)
    task_opts = Keyword.delete(opts, :timeout)

    task =
      Task.Supervisor.async_nolink(SefazNfe.TaskSupervisor, fn ->
        client().call(endpoint, body, cert, task_opts)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:soap_crash, reason}}
    end
  end

  defmodule NotImplemented do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(_endpoint, _body, _cert, _opts), do: {:error, :not_implemented}
  end
end
