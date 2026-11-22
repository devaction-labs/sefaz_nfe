defmodule SefazNfe.CTe do
  @moduledoc """
  CT-e (modelo 57) and CT-e OS (modelo 67) transport.

  Only `service_status/1` so far: the cheapest call there is, and the one that
  proves the certificate, the mTLS handshake and the CT-e endpoint table in a
  single round trip. The authorizer is per model, not per UF (BA is SVRS for
  CT-e, PE is SVSP); see `SefazNfe.Endpoints`.
  """

  alias SefazNfe.Endpoints
  alias SefazNfe.Result
  alias SefazNfe.SOAP.Envelope
  alias SefazNfe.Telemetry

  import SefazNfe.Transport, only: [call: 4, require_keys: 2, validate_environment: 1]

  @doc """
  `CTeStatusServicoV4` for one UF.

  Options: `:cert`, `:uf` and `:environment`, and `:model` (57 by default, or
  67). `cStat` 107 is `:in_operation`; 108 and 109 are `:retryable`, and all
  arrive as `{:ok, result}` because SEFAZ answered. See `SefazNfe.CStat`.
  """
  @spec service_status(map()) :: {:ok, Result.t()} | {:error, term()}
  def service_status(opts) when is_map(opts) do
    Telemetry.span(:cte_service_status, opts, &do_service_status/1)
  end

  defp do_service_status(opts) do
    with :ok <- require_keys(opts, [:cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         {:ok, model} <- model(opts),
         {:ok, url} <- Endpoints.url(opts.uf, opts.environment, :cte_status_servico, model),
         {:ok, uf_code} <- Endpoints.uf_code(opts.uf),
         message = Envelope.status_service_cte(uf_code, Envelope.tp_amb(opts.environment)),
         {:ok, envelope} <- Envelope.wrap(:cte_status_servico, message),
         {:ok, body} <- call(url, envelope, opts, :cte_status_servico) do
      Result.parse(body)
    end
  end

  defp model(opts) do
    case Map.get(opts, :model, 57) do
      model when model in [57, 67] -> {:ok, model}
      other -> {:error, {:unsupported_model, other}}
    end
  end
end
