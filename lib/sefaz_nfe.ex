defmodule SefazNfe do
  @moduledoc """
  SEFAZ NF-e **transport** (modelo 55).

  Does not calculate taxes. The ERP builds the XML; this library signs and
  talks to the official 4.00 webservices (and DistDFe 1.00 on the AN).

  SOAP is not implemented yet — public functions validate input and resolve
  endpoints, then return `{:error, :not_implemented}`.
  """

  alias SefazNfe.DistDFe.Poller
  alias SefazNfe.Endpoints

  @justificativa_min 15

  @doc "Sign + `NFeAutorizacao4`. Does not mutate tax nodes once SOAP exists."
  @spec authorize(map()) :: {:ok, SefazNfe.Result.t()} | {:error, term()}
  def authorize(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:xml, :cert, :uf, :ambiente]),
         :ok <- validate_ambiente(opts.ambiente),
         :ok <- reject_an(opts.uf, :nfe_autorizacao),
         :ok <- ambiente_matches_xml(opts.ambiente, opts.xml),
         {:ok, url} <- Endpoints.url(opts.uf, opts.ambiente, :nfe_autorizacao) do
      SefazNfe.SOAP.isolated_call(url, opts.xml, opts.cert)
    end
  end

  @doc "`NFeRetAutorizacao4` for a recibo (`n_rec`)."
  @spec ret_autorizacao(map()) :: {:ok, SefazNfe.Result.t()} | {:error, term()}
  def ret_autorizacao(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:n_rec, :cert, :uf, :ambiente]),
         :ok <- validate_ambiente(opts.ambiente),
         {:ok, _url} <- Endpoints.url(opts.uf, opts.ambiente, :nfe_ret_autorizacao) do
      {:error, :not_implemented}
    end
  end

  @doc "`NFeStatusServico4`."
  @spec status_servico(map()) :: {:ok, map()} | {:error, term()}
  def status_servico(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:cert, :uf, :ambiente]),
         :ok <- validate_ambiente(opts.ambiente),
         {:ok, _url} <- Endpoints.url(opts.uf, opts.ambiente, :nfe_status_servico) do
      {:error, :not_implemented}
    end
  end

  @doc "`NFeDistribuicaoDFe` on the Ambiente Nacional. Caller persists `ult_nsu`."
  @spec dist_dfe(map()) :: {:ok, SefazNfe.DistDFe.t()} | {:error, term()}
  def dist_dfe(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:cert, :ambiente]),
         :ok <- validate_ambiente(opts.ambiente),
         :ok <- dist_query(opts),
         {:ok, _url} <- Endpoints.url("AN", opts.ambiente, :nfe_distribuicao_dfe) do
      {:error, :not_implemented}
    end
  end

  @doc "`NFeConsultaProtocolo4` by 44-digit access key."
  @spec consulta_protocolo(map()) :: {:ok, SefazNfe.Result.t()} | {:error, term()}
  def consulta_protocolo(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:ch_nfe, :cert, :uf, :ambiente]),
         :ok <- validate_ambiente(opts.ambiente),
         :ok <- validate_ch_nfe(opts.ch_nfe),
         {:ok, _url} <- Endpoints.url(opts.uf, opts.ambiente, :nfe_consulta_protocolo) do
      {:error, :not_implemented}
    end
  end

  @doc "Event 110111 via `NFeRecepcaoEvento4`."
  @spec cancela(map()) :: {:ok, SefazNfe.Result.t()} | {:error, term()}
  def cancela(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:ch_nfe, :n_prot, :justificativa, :cert, :uf, :ambiente]),
         :ok <- validate_ambiente(opts.ambiente),
         :ok <- validate_ch_nfe(opts.ch_nfe),
         :ok <- validate_justificativa(opts.justificativa),
         {:ok, _url} <- Endpoints.url(opts.uf, opts.ambiente, :nfe_recepcao_evento) do
      {:error, :not_implemented}
    end
  end

  @doc "Event 110110 (CCe) via `NFeRecepcaoEvento4`."
  @spec cce(map()) :: {:ok, SefazNfe.Result.t()} | {:error, term()}
  def cce(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:ch_nfe, :correcao, :cert, :uf, :ambiente]),
         :ok <- validate_ambiente(opts.ambiente),
         :ok <- validate_ch_nfe(opts.ch_nfe),
         {:ok, _url} <- Endpoints.url(opts.uf, opts.ambiente, :nfe_recepcao_evento) do
      {:error, :not_implemented}
    end
  end

  @doc """
  Starts a DistDFe poller for one CNPJ under `SefazNfe.DistDFe.Supervisor`.

  `opts` must include `:cnpj` and `:cert`. Optional `:ambiente`, `:ult_nsu`,
  `:interval` (`Duration.t()`, default 5 minutes).
  """
  @spec start_dist_dfe_poller(keyword()) :: DynamicSupervisor.on_start_child()
  def start_dist_dfe_poller(opts) when is_list(opts) do
    DynamicSupervisor.start_child(SefazNfe.DistDFe.Supervisor, {Poller, opts})
  end

  @doc "`NFeInutilizacao4`."
  @spec inutiliza(map()) :: {:ok, SefazNfe.Result.t()} | {:error, term()}
  def inutiliza(opts) when is_map(opts) do
    with :ok <-
           require_keys(opts, [:serie, :n_ini, :n_fim, :justificativa, :cert, :uf, :ambiente]),
         :ok <- validate_ambiente(opts.ambiente),
         :ok <- validate_justificativa(opts.justificativa),
         {:ok, _url} <- Endpoints.url(opts.uf, opts.ambiente, :nfe_inutilizacao) do
      {:error, :not_implemented}
    end
  end

  defp require_keys(opts, keys) do
    missing = Enum.reject(keys, &Map.has_key?(opts, &1))

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_keys, keys}}
    end
  end

  defp validate_ambiente(ambiente) when ambiente in [:homologacao, :producao], do: :ok
  defp validate_ambiente(_), do: {:error, :invalid_ambiente}

  defp reject_an(uf, service) do
    case String.upcase(to_string(uf)) do
      "AN" -> {:error, {:unknown_endpoint, "AN", service}}
      _ -> :ok
    end
  end

  defp ambiente_matches_xml(_ambiente, xml) when not is_binary(xml), do: {:error, :invalid_xml}

  defp ambiente_matches_xml(ambiente, xml) do
    case Regex.run(~r/<tpAmb>([12])<\/tpAmb>/, xml, capture: :all_but_first) do
      [tp] ->
        expected = if ambiente == :producao, do: "1", else: "2"

        if tp == expected do
          :ok
        else
          {:error, :ambiente_mismatch}
        end

      nil ->
        :ok
    end
  end

  defp validate_ch_nfe(ch) when is_binary(ch) and byte_size(ch) == 44 do
    if String.match?(ch, ~r/^\d{44}$/), do: :ok, else: {:error, :invalid_ch_nfe}
  end

  defp validate_ch_nfe(_), do: {:error, :invalid_ch_nfe}

  defp validate_justificativa(text) when is_binary(text) do
    if String.length(text) >= @justificativa_min, do: :ok, else: {:error, :justificativa_curta}
  end

  defp validate_justificativa(_), do: {:error, :justificativa_curta}

  defp dist_query(opts) do
    cond do
      Map.has_key?(opts, :ult_nsu) -> :ok
      Map.has_key?(opts, :nsu) -> :ok
      Map.has_key?(opts, :ch_nfe) -> validate_ch_nfe(opts.ch_nfe)
      true -> {:error, {:missing_keys, [:ult_nsu]}}
    end
  end
end
