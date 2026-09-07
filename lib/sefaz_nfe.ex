defmodule SefazNfe do
  @moduledoc """
  SEFAZ NF-e **transport** (modelo 55).

  Does not calculate taxes. The ERP builds the XML; this library signs and
  talks to the official 4.00 webservices (and DistDFe 1.00 on the AN).

  `service_status/1` is live over mTLS. The remaining services validate input
  and resolve endpoints, then return `{:error, :not_implemented}` until their
  message builders and XMLDSig land.
  """

  alias SefazNfe.DistDFe.Poller
  alias SefazNfe.Endpoints
  alias SefazNfe.Result
  alias SefazNfe.Signer
  alias SefazNfe.SOAP
  alias SefazNfe.SOAP.Envelope

  @justification_min 15
  @tp_amb ~r|<tpAmb>([12])</tpAmb>|

  @doc """
  Sign + `NFeAutorizacao4`. Does not mutate tax nodes once SOAP exists.

  The whole pipeline is `sign -> POST -> parse`; it currently stops at
  `SefazNfe.Signer.sign_nfe/2` with `{:error, :not_implemented}`.

  `tpAmb` is MOC data rather than a boolean — 1 is produção, 2 is homologação —
  so a mismatch against `:environment` is refused before anything is sent.
  """
  @spec authorize(map()) :: {:ok, Result.t()} | {:error, term()}
  def authorize(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:xml, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- reject_an(opts.uf, :nfe_autorizacao),
         :ok <- environment_matches_xml(opts.environment, opts.xml),
         {:ok, url} <- Endpoints.url(opts.uf, opts.environment, :nfe_autorizacao),
         {:ok, signed} <- Signer.sign_nfe(opts.xml, opts.cert),
         {:ok, body} <-
           SOAP.isolated_call(url, signed, opts.cert,
             uf: opts.uf,
             service: :nfe_autorizacao
           ) do
      Result.parse(body)
    end
  end

  @doc "`NFeRetAutorizacao4` for a recibo (`n_rec`)."
  @spec authorization_result(map()) :: {:ok, SefazNfe.Result.t()} | {:error, term()}
  def authorization_result(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:n_rec, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         {:ok, _url} <- Endpoints.url(opts.uf, opts.environment, :nfe_ret_autorizacao) do
      {:error, :not_implemented}
    end
  end

  @doc """
  `NFeStatusServico4` for one UF.

  The cheapest official call there is, and the one that proves the A1, the mTLS
  handshake and the endpoint table in a single round trip. `cStat` 107 means the
  authorizer is in operation; 108 and 109 mean it is not, and both arrive as
  `{:ok, result}` because SEFAZ answered.
  """
  @spec service_status(map()) :: {:ok, Result.t()} | {:error, term()}
  def service_status(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         {:ok, url} <- Endpoints.url(opts.uf, opts.environment, :nfe_status_servico),
         {:ok, uf_code} <- Endpoints.uf_code(opts.uf),
         message = Envelope.status_service(uf_code, Envelope.tp_amb(opts.environment)),
         {:ok, envelope} <- Envelope.wrap(:nfe_status_servico, message),
         {:ok, body} <- call(url, envelope, opts, :nfe_status_servico) do
      Result.parse(body)
    end
  end

  @doc """
  `NFeDistribuicaoDFe` on the Ambiente Nacional. Caller persists `ult_nsu`.

  `:tax_id` is the CNPJ or CPF of the interested party — the `distDFeInt`
  envelope carries it, so it is required even though the URL is always the AN.

  A CPF is 11 digits; a CNPJ is 14 and alphanumeric since NT 2025.002 (CNPJ
  alfa), meaning 12 characters of `[A-Z0-9]` plus a two digit DV. Only the shape
  is checked here — the check digits and the registration itself are SEFAZ's to
  validate.
  """
  @spec dist_dfe(map()) :: {:ok, SefazNfe.DistDFe.t()} | {:error, term()}
  def dist_dfe(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:tax_id, :cert, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_tax_id(opts.tax_id),
         :ok <- dist_query(opts),
         {:ok, _url} <- Endpoints.url("AN", opts.environment, :nfe_distribuicao_dfe) do
      {:error, :not_implemented}
    end
  end

  @doc "`NFeConsultaProtocolo4` by 44-digit access key."
  @spec consult_protocol(map()) :: {:ok, SefazNfe.Result.t()} | {:error, term()}
  def consult_protocol(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:ch_nfe, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_ch_nfe(opts.ch_nfe),
         {:ok, _url} <- Endpoints.url(opts.uf, opts.environment, :nfe_consulta_protocolo) do
      {:error, :not_implemented}
    end
  end

  @doc "Event 110111 via `NFeRecepcaoEvento4`."
  @spec cancel(map()) :: {:ok, SefazNfe.Result.t()} | {:error, term()}
  def cancel(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:ch_nfe, :n_prot, :justification, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_ch_nfe(opts.ch_nfe),
         :ok <- validate_justification(opts.justification),
         {:ok, _url} <- Endpoints.url(opts.uf, opts.environment, :nfe_recepcao_evento) do
      {:error, :not_implemented}
    end
  end

  @doc "Event 110110 (CCe) via `NFeRecepcaoEvento4`."
  @spec cce(map()) :: {:ok, SefazNfe.Result.t()} | {:error, term()}
  def cce(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:ch_nfe, :correcao, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_ch_nfe(opts.ch_nfe),
         {:ok, _url} <- Endpoints.url(opts.uf, opts.environment, :nfe_recepcao_evento) do
      {:error, :not_implemented}
    end
  end

  @doc """
  Starts a DistDFe poller for one tax ID under `SefazNfe.DistDFe.Supervisor`.

  `opts` must include `:tax_id`, `:cert` and `:handler` — the poller delivers
  every page to the handler, which owns the cursor. See
  `SefazNfe.DistDFe.Poller` for the handler contract and the remaining options
  (`:environment`, `:ult_nsu`, `:interval`, `:fetch`).
  """
  @spec start_dist_dfe_poller(keyword()) :: DynamicSupervisor.on_start_child()
  def start_dist_dfe_poller(opts) when is_list(opts) do
    DynamicSupervisor.start_child(SefazNfe.DistDFe.Supervisor, {Poller, opts})
  end

  @doc "`NFeInutilizacao4`."
  @spec void_numbers(map()) :: {:ok, SefazNfe.Result.t()} | {:error, term()}
  def void_numbers(opts) when is_map(opts) do
    with :ok <-
           require_keys(opts, [:serie, :n_ini, :n_fim, :justification, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_justification(opts.justification),
         {:ok, _url} <- Endpoints.url(opts.uf, opts.environment, :nfe_inutilizacao) do
      {:error, :not_implemented}
    end
  end

  defp call(url, envelope, opts, service) do
    SOAP.isolated_call(url, envelope, opts.cert,
      uf: to_string(opts.uf),
      service: service,
      timeout: Map.get(opts, :timeout, to_timeout(second: 30)),
      tls_options: Map.get(opts, :tls_options, [])
    )
  end

  defp require_keys(opts, keys) do
    missing = Enum.reject(keys, &Map.has_key?(opts, &1))

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_keys, keys}}
    end
  end

  defp validate_environment(environment) when environment in [:homologation, :production], do: :ok
  defp validate_environment(_), do: {:error, :invalid_environment}

  defp reject_an(uf, service) do
    case String.upcase(to_string(uf)) do
      "AN" -> {:error, {:unknown_endpoint, "AN", service}}
      _ -> :ok
    end
  end

  defp environment_matches_xml(_environment, xml) when not is_binary(xml),
    do: {:error, :invalid_xml}

  defp environment_matches_xml(environment, xml) do
    case Regex.run(@tp_amb, xml, capture: :all_but_first) do
      [tp] -> environment_matches_tp_amb(environment, tp)
      nil -> :ok
    end
  end

  defp environment_matches_tp_amb(:production, "1"), do: :ok
  defp environment_matches_tp_amb(:homologation, "2"), do: :ok
  defp environment_matches_tp_amb(_environment, _tp), do: {:error, :environment_mismatch}

  defp validate_ch_nfe(ch) when is_binary(ch) and byte_size(ch) == 44 do
    if String.match?(ch, ~r/^\d{44}$/), do: :ok, else: {:error, :invalid_ch_nfe}
  end

  defp validate_ch_nfe(_), do: {:error, :invalid_ch_nfe}

  defp validate_tax_id(id) when is_binary(id) and byte_size(id) == 11 do
    if String.match?(id, ~r/^\d{11}$/), do: :ok, else: {:error, :invalid_tax_id}
  end

  defp validate_tax_id(id) when is_binary(id) and byte_size(id) == 14 do
    if String.match?(id, ~r/^[A-Z0-9]{12}\d{2}$/), do: :ok, else: {:error, :invalid_tax_id}
  end

  defp validate_tax_id(_), do: {:error, :invalid_tax_id}

  defp validate_justification(text) when is_binary(text) do
    if String.length(text) >= @justification_min,
      do: :ok,
      else: {:error, :justification_too_short}
  end

  defp validate_justification(_), do: {:error, :justification_too_short}

  defp dist_query(opts) do
    cond do
      Map.has_key?(opts, :ult_nsu) -> :ok
      Map.has_key?(opts, :nsu) -> :ok
      Map.has_key?(opts, :ch_nfe) -> validate_ch_nfe(opts.ch_nfe)
      true -> {:error, {:missing_keys, [:ult_nsu]}}
    end
  end
end
