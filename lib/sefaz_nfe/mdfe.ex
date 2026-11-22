defmodule SefazNfe.MDFe do
  @moduledoc """
  MDF-e (modelo 58) transport.

  Only `service_status/1` so far. SVRS authorizes MDF-e for every UF, so `:uf`
  selects nothing but the circuit breaker and the telemetry tag.
  """

  alias SefazNfe.Endpoints
  alias SefazNfe.Result
  alias SefazNfe.SOAP.Envelope
  alias SefazNfe.Telemetry

  import SefazNfe.Transport, only: [call: 4, require_keys: 2, validate_environment: 1]

  @doc """
  `MDFeStatusServico` for one UF.

  Options: `:cert`, `:uf` and `:environment`. `cStat` 107 is `:in_operation`;
  108 and 109 are `:retryable`, and all arrive as `{:ok, result}` because SEFAZ
  answered. See `SefazNfe.CStat`.
  """
  @spec service_status(map()) :: {:ok, Result.t()} | {:error, term()}
  def service_status(opts) when is_map(opts) do
    Telemetry.span(:mdfe_service_status, opts, &do_service_status/1)
  end

  defp do_service_status(opts) do
    with :ok <- require_keys(opts, [:cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         {:ok, url} <- Endpoints.url(opts.uf, opts.environment, :mdfe_status_servico, 58),
         message = Envelope.status_service_mdfe(Envelope.tp_amb(opts.environment)),
         {:ok, envelope} <- Envelope.wrap(:mdfe_status_servico, message),
         {:ok, body} <- call(url, envelope, opts, :mdfe_status_servico) do
      Result.parse(body)
    end
  end
end
