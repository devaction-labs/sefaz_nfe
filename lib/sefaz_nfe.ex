defmodule SefazNfe do
  @moduledoc """
  SEFAZ NF-e **transport** (modelo 55).

  Does not calculate taxes. The ERP builds the XML; this library signs and
  talks to the official 4.00 webservices (and DistDFe 1.00 on the AN).

  Every service is live over mTLS. The library signs, sends and parses; it
  never composes an NF-e (AD-001), so `authorize/1` takes the XML the ERP
  built and returns it to SEFAZ byte for byte.
  """

  alias SefazNfe.DistDFe
  alias SefazNfe.DistDFe.Poller
  alias SefazNfe.Endpoints
  alias SefazNfe.Events
  alias SefazNfe.Result
  alias SefazNfe.Schema
  alias SefazNfe.Signer
  alias SefazNfe.SOAP
  alias SefazNfe.SOAP.Envelope

  @justification_min 15
  @tp_amb ~r|<tpAmb>([12])</tpAmb>|

  @doc """
  Sign + `NFeAutorizacao4`. Does not mutate tax nodes once SOAP exists.

  The pipeline is validate, sign, wrap in `enviNFe`, POST, parse. `:sync` asks
  SEFAZ to answer with the protocol in the same call instead of a receipt.

  XSD validation runs only when `SefazNfe.Schema` is configured, and then it
  fails before the network — a local error naming the offending element beats
  `cStat` 225, which names nothing.

  The result carries `:signed_xml` — what was sent — and, once a protocol
  exists, `:xml` holding the `nfeProc`. Store `:signed_xml` even on a receipt:
  an asynchronous lote answers `cStat` 103 with no protocol, and without those
  bytes the protocol collected later by `authorization_result/1` cannot be
  attached to anything. `SefazNfe.Result.proc/2` joins the two.

  `tpAmb` is MOC data rather than a boolean — 1 is produção, 2 is homologação —
  so a mismatch against `:environment` is refused before anything is sent.
  """
  @spec authorize(map()) :: {:ok, Result.t()} | {:error, term()}
  def authorize(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:xml, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- reject_an(opts.uf, :nfe_autorizacao),
         :ok <- environment_matches_xml(opts.environment, opts.xml),
         :ok <- Schema.validate(opts.xml, Map.get(opts, :schema, "nfe_v4.00.xsd")),
         {:ok, url} <- Endpoints.url(opts.uf, opts.environment, :nfe_autorizacao),
         {:ok, signed} <- Signer.sign_nfe(opts.xml, opts.cert),
         message = Envelope.send_nfe(signed, Map.get(opts, :id_lote, "1"), ind_sinc(opts)),
         {:ok, envelope} <- Envelope.wrap(:nfe_autorizacao, message),
         {:ok, body} <- call(url, envelope, opts, :nfe_autorizacao),
         {:ok, result} <- Result.parse(body) do
      {:ok, %{result | signed_xml: signed, xml: Result.proc(signed, body)}}
    end
  end

  # The MOC leaves the choice to the caller; v1 defaults to asynchronous, so a
  # lote answers a receipt that `authorization_result/1` then consults.
  defp ind_sinc(opts), do: if(Map.get(opts, :sync, false), do: 1, else: 0)

  @doc """
  `NFeRetAutorizacao4` for a receipt (`n_rec`).

  What an asynchronous `authorize/1` leaves to be collected. `cStat` 105 means
  the batch is still processing and the caller should ask again; 104 means it
  finished, and the document's own outcome is read from the nested protocol.
  """
  @spec authorization_result(map()) :: {:ok, Result.t()} | {:error, term()}
  def authorization_result(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:n_rec, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         {:ok, url} <- Endpoints.url(opts.uf, opts.environment, :nfe_ret_autorizacao),
         message = Envelope.authorization_result(opts.n_rec, Envelope.tp_amb(opts.environment)),
         {:ok, envelope} <- Envelope.wrap(:nfe_ret_autorizacao, message),
         {:ok, body} <- call(url, envelope, opts, :nfe_ret_autorizacao) do
      Result.parse(body)
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
  `:uf` is the querying party's own state, which the envelope carries as
  `cUFAutor`. It is required and must be a real UF: the Ambiente Nacional's own
  code is rejected there as `cStat` 215.

  A CPF is 11 digits; a CNPJ is 14 and alphanumeric since NT 2025.002 (CNPJ
  alfa), meaning 12 characters of `[A-Z0-9]` plus a two digit DV. Only the shape
  is checked here — the check digits and the registration itself are SEFAZ's to
  validate.
  """
  @spec dist_dfe(map()) :: {:ok, SefazNfe.DistDFe.t()} | {:error, term()}
  def dist_dfe(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:tax_id, :uf, :cert, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_tax_id(opts.tax_id),
         {:ok, cursor} <- dist_cursor(opts),
         {:ok, url} <- Endpoints.url("AN", opts.environment, :nfe_distribuicao_dfe),
         {:ok, uf_code} <- Endpoints.uf_code(opts.uf),
         message =
           Envelope.dist_dfe(
             opts.tax_id,
             uf_code,
             Envelope.tp_amb(opts.environment),
             cursor
           ),
         {:ok, envelope} <- Envelope.wrap(:nfe_distribuicao_dfe, message),
         {:ok, body} <- call(url, envelope, opts, :nfe_distribuicao_dfe) do
      DistDFe.parse(body)
    end
  end

  @doc """
  `NFeConsultaProtocolo4` by 44-digit access key.

  The idempotent way back after a crash between a receipt and a protocol: ask
  SEFAZ what it did with a document instead of sending the batch again.
  """
  @spec consult_protocol(map()) :: {:ok, Result.t()} | {:error, term()}
  def consult_protocol(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:ch_nfe, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_ch_nfe(opts.ch_nfe),
         {:ok, url} <- Endpoints.url(opts.uf, opts.environment, :nfe_consulta_protocolo),
         message = Envelope.consult_protocol(opts.ch_nfe, Envelope.tp_amb(opts.environment)),
         {:ok, envelope} <- Envelope.wrap(:nfe_consulta_protocolo, message),
         {:ok, body} <- call(url, envelope, opts, :nfe_consulta_protocolo) do
      Result.parse(body)
    end
  end

  @doc """
  Event 110111, cancelling an authorized NF-e via `NFeRecepcaoEvento4`.

  Needs the protocol the authorization returned, and a justification of at
  least 15 characters as the MOC requires.
  """
  @spec cancel(map()) :: {:ok, Result.t()} | {:error, term()}
  def cancel(opts) when is_map(opts) do
    with :ok <-
           require_keys(opts, [
             :ch_nfe,
             :n_prot,
             :justification,
             :tax_id,
             :cert,
             :uf,
             :environment
           ]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_ch_nfe(opts.ch_nfe),
         :ok <- validate_tax_id(opts.tax_id),
         :ok <- validate_justification(opts.justification) do
      send_event(opts, &Events.cancel/1)
    end
  end

  @doc """
  Event 110110, the Carta de Correção Eletrônica, via `NFeRecepcaoEvento4`.

  `:sequence` numbers the correction; each one replaces the previous text
  rather than adding to it.
  """
  @spec cce(map()) :: {:ok, Result.t()} | {:error, term()}
  def cce(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:ch_nfe, :correction, :tax_id, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_ch_nfe(opts.ch_nfe),
         :ok <- validate_tax_id(opts.tax_id),
         :ok <- validate_justification(opts.correction) do
      send_event(opts, &Events.correction/1)
    end
  end

  @doc """
  Manifestação do destinatário for a document received through DistDFe.

  `type` is one of `:confirmation`, `:awareness`, `:unaware` or
  `:not_performed`; the last one needs a `:justification`. Confirming an
  operation is also what releases the full XML of a note DistDFe only
  summarised.

  These events are processed by the Ambiente Nacional, so no `:uf` is needed.
  """
  @spec manifest(atom(), map()) :: {:ok, Result.t()} | {:error, term()}
  def manifest(type, opts) when is_atom(type) and is_map(opts) do
    with :ok <- require_keys(opts, [:ch_nfe, :tax_id, :cert, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_ch_nfe(opts.ch_nfe),
         :ok <- validate_tax_id(opts.tax_id),
         :ok <- validate_manifestation(type, opts) do
      opts
      |> Map.put(:uf, "AN")
      |> send_event(&Events.manifestation(type, &1))
    end
  end

  defp validate_manifestation(type, opts) do
    cond do
      type not in [:confirmation, :awareness, :unaware, :not_performed] ->
        {:error, {:unknown_manifestation, type}}

      type == :not_performed ->
        with :ok <- require_keys(opts, [:justification]),
             do: validate_justification(opts.justification)

      true ->
        :ok
    end
  end

  defp send_event(opts, build) do
    with {:ok, url} <- Endpoints.url(opts.uf, opts.environment, :nfe_recepcao_evento),
         {:ok, uf_code} <- Endpoints.uf_code(opts.uf),
         event = build.(event_opts(opts, uf_code)),
         {:ok, signed} <- Signer.sign(event, opts.cert, "infEvento", "evento"),
         message = Envelope.send_event(signed, Map.get(opts, :id_lote, "1")),
         {:ok, envelope} <- Envelope.wrap(:nfe_recepcao_evento, message),
         {:ok, body} <- call(url, envelope, opts, :nfe_recepcao_evento) do
      Result.parse(body)
    end
  end

  defp event_opts(opts, uf_code) do
    Map.merge(opts, %{uf_code: uf_code, tp_amb: Envelope.tp_amb(opts.environment)})
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

  @doc """
  `NFeInutilizacao4`, closing a range of NF-e numbers that was never used.

  A broken sequence still has to be accounted for, and this is how. `:model`
  defaults to 55 and `:year` to the current one.
  """
  @spec void_numbers(map()) :: {:ok, Result.t()} | {:error, term()}
  def void_numbers(opts) when is_map(opts) do
    with :ok <-
           require_keys(opts, [
             :serie,
             :n_ini,
             :n_fim,
             :justification,
             :tax_id,
             :cert,
             :uf,
             :environment
           ]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_tax_id(opts.tax_id),
         :ok <- validate_justification(opts.justification),
         {:ok, url} <- Endpoints.url(opts.uf, opts.environment, :nfe_inutilizacao),
         {:ok, uf_code} <- Endpoints.uf_code(opts.uf),
         message = Events.void_numbers(void_opts(opts, uf_code)),
         {:ok, signed} <- Signer.sign(message, opts.cert, "infInut", "inutNFe"),
         {:ok, envelope} <- Envelope.wrap(:nfe_inutilizacao, signed),
         {:ok, body} <- call(url, envelope, opts, :nfe_inutilizacao) do
      Result.parse(body)
    end
  end

  defp void_opts(opts, uf_code) do
    Map.merge(opts, %{
      uf_code: uf_code,
      tp_amb: Envelope.tp_amb(opts.environment),
      model: Map.get(opts, :model, 55)
    })
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

  defp dist_cursor(opts) do
    cond do
      Map.has_key?(opts, :ult_nsu) -> {:ok, {:ult_nsu, opts.ult_nsu}}
      Map.has_key?(opts, :nsu) -> {:ok, {:nsu, opts.nsu}}
      Map.has_key?(opts, :ch_nfe) -> chave_cursor(opts.ch_nfe)
      true -> {:error, {:missing_keys, [:ult_nsu]}}
    end
  end

  defp chave_cursor(ch_nfe) do
    with :ok <- validate_ch_nfe(ch_nfe), do: {:ok, {:ch_nfe, ch_nfe}}
  end
end
