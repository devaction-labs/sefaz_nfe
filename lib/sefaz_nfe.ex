defmodule SefazNfe do
  @moduledoc """
  SEFAZ NF-e and NFC-e **transport** (modelos 55 and 65).

  Does not calculate taxes. The ERP builds the XML; this library signs and
  talks to the official 4.00 webservices (and DistDFe 1.00 on the AN).

  Every service is live over mTLS. The library signs, sends and parses; it
  never composes an NF-e (AD-001), so `authorize/1` takes the XML the ERP
  built and returns it to SEFAZ byte for byte.
  """

  alias SefazNfe.DistDFe
  alias SefazNfe.DistDFe.Poller
  alias SefazNfe.Endpoints
  alias SefazNfe.EPEC
  alias SefazNfe.Events
  alias SefazNfe.NFCe
  alias SefazNfe.Result
  alias SefazNfe.Schema
  alias SefazNfe.Signer
  alias SefazNfe.TaxpayerLookup
  alias SefazNfe.SOAP
  alias SefazNfe.SOAP.Envelope

  @justification_min 15
  @tp_amb ~r|<tpAmb>([12])</tpAmb>|

  @doc """
  Sign + `NFeAutorizacao4`. Does not mutate tax nodes once SOAP exists.

  The pipeline is validate, sign, wrap in `enviNFe`, POST, parse.

  The lote is synchronous by default: it carries one document, and SEFAZ
  rejects an asynchronous request for a single-document batch as `cStat` 452.
  When SEFAZ answers a receipt anyway — it may, under load — the protocol is
  collected later with `authorization_result/1`.

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

  The model is read from `<mod>`: 55 goes to the NF-e endpoints and 65 to the
  NFC-e ones; anything else is `{:error, {:unsupported_model, mod}}`. For a
  model 65 document `infNFeSupl` (with the on-line QR code 3.00) is added after
  signing unless the XML already has one; see `SefazNfe.NFCe`. `:uf` is the
  emitting UF, which selects the QR code address even where SVRS authorizes.
  `:qr_code_version` (`3`, the default, or `2`), `:csc` and `:csc_id` select the
  CSC based QR code 2.00, on-line or off-line; the CSC is a secret and is never
  logged nor returned in an error.

  ## Contingency (model 55)

  Contingency is the caller's choice (AD-005): this library never falls back to
  it, and it builds no XML, so the ERP rebuilds the document with the new
  `tpEmis` and this function routes on it:

    * `1` goes to the emitting UF's own authorizer;
    * `6` goes to SVC-AN and `7` to SVC-RS, but only when that SVC is the one
      that serves `:uf` (`SefazNfe.Endpoints.contingency_for/1`); otherwise
      `{:error, {:wrong_contingency, uf, svc}}`, where `svc` is the SVC that
      does serve it;
    * `4` is an NF-e under EPEC (`epec/1`) coming back: it goes to the ORIGIN
      authorizer, keeping `tpEmis` 4;
    * `2`, `3` and `5` (FS-IA, SCAN, FS-DA) are
      `{:error, {:unsupported, {:tp_emis, n}}}`.

  For `4`, `6` and `7` the MOC requires `dhCont` and `xJust` in `ide`; their
  absence is `{:error, {:missing_contingency_fields, [:dh_cont, :x_just]}}`
  (whichever is missing), before the network. NFC-e (model 65) has no SVC.
  """
  @spec authorize(map()) :: {:ok, Result.t()} | {:error, term()}
  def authorize(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:xml, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- reject_an(opts.uf, :nfe_autorizacao),
         :ok <- environment_matches_xml(opts.environment, opts.xml),
         {:ok, doc} <- SefazNfe.XML.parse(opts.xml),
         {:ok, model} <- model_from_mod(SefazNfe.XML.text(doc, "mod")),
         :ok <- Schema.validate(opts.xml, Map.get(opts, :schema, "nfe_v4.00.xsd")),
         {:ok, url} <- authorize_url(opts, model, doc),
         {:ok, signed} <- Signer.sign_nfe(opts.xml, opts.cert),
         {:ok, signed} <- put_supl(signed, model, opts),
         message = Envelope.send_nfe(signed, Map.get(opts, :id_lote, "1"), ind_sinc(opts)),
         {:ok, envelope} <- Envelope.wrap(:nfe_autorizacao, message),
         {:ok, body} <- call(url, envelope, opts, :nfe_autorizacao),
         {:ok, result} <- Result.parse(body) do
      {:ok, %{result | signed_xml: signed, xml: Result.proc(signed, body)}}
    end
  end

  # Model 65 has no SVC and its off-line mode is handled by `SefazNfe.NFCe`, so
  # `tpEmis` only routes a model 55 document.
  defp authorize_url(opts, 65, _doc),
    do: Endpoints.url(opts.uf, opts.environment, :nfe_autorizacao, 65)

  defp authorize_url(opts, 55, doc) do
    nfe_emission_url(SefazNfe.XML.text(doc, "tpEmis"), opts, doc)
  end

  # 1 is normal. 4 is an NF-e that went out under EPEC: it is transmitted to
  # the ORIGIN authorizer keeping tpEmis 4, not to an SVC. 6 and 7 are SVC-AN
  # and SVC-RS, and only the SVC that serves the emitter UF will take it.
  # 2, 3 and 5 (FS-IA, SCAN, FS-DA) are not supported.
  # An absent tpEmis is the XSD's to refuse (it is mandatory), not a routing
  # decision: it keeps the origin routing it always had.
  defp nfe_emission_url("1", opts, _doc), do: origin_url(opts)
  defp nfe_emission_url(nil, opts, _doc), do: origin_url(opts)

  defp nfe_emission_url("4", opts, doc) do
    with :ok <- contingency_fields(doc), do: origin_url(opts)
  end

  defp nfe_emission_url("6", opts, doc), do: svc_authorize_url(:svc_an, opts, doc)
  defp nfe_emission_url("7", opts, doc), do: svc_authorize_url(:svc_rs, opts, doc)
  defp nfe_emission_url(tp_emis, _opts, _doc), do: {:error, {:unsupported, {:tp_emis, tp_emis}}}

  defp origin_url(opts), do: Endpoints.url(opts.uf, opts.environment, :nfe_autorizacao, 55)

  defp svc_authorize_url(svc, opts, doc) do
    with {:ok, url} <- route(Map.put(opts, :contingency, svc), :nfe_autorizacao, 55),
         :ok <- contingency_fields(doc) do
      {:ok, url}
    end
  end

  # The MOC requires dhCont and xJust in `ide` whenever tpEmis is 4, 6 or 7.
  # The library does not build the XML, so it only checks they are there, before
  # SEFAZ answers with a schema or business rejection that names neither.
  defp contingency_fields(doc) do
    missing =
      for {name, field} <- [{"dhCont", :dh_cont}, {"xJust", :x_just}],
          SefazNfe.XML.text(doc, name) in [nil, ""],
          do: field

    case missing do
      [] -> :ok
      fields -> {:error, {:missing_contingency_fields, fields}}
    end
  end

  # Where `service` is called for `opts.uf`: its own authorizer, or the SVC the
  # caller names in `:contingency` (AD-005: never inferred). Only a model 55
  # document has an SVC, and only the one that serves the UF is accepted; the
  # error names the SVC that does.
  defp route(opts, service, model) do
    case Map.get(opts, :contingency) do
      nil -> Endpoints.url(opts.uf, opts.environment, service, model)
      svc -> svc_route(svc, opts, service, model)
    end
  end

  defp svc_route(svc, _opts, _service, _model) when svc not in [:svc_an, :svc_rs],
    do: {:error, {:invalid_contingency, svc}}

  defp svc_route(_svc, _opts, _service, 65), do: {:error, {:unsupported_for_model, 65}}

  defp svc_route(svc, opts, service, 55) do
    with {:ok, expected} <- Endpoints.contingency_for(opts.uf) do
      case expected do
        ^svc ->
          Endpoints.contingency_url(svc, opts.environment, service)

        other ->
          {:error, {:wrong_contingency, opts.uf |> to_string() |> String.upcase(), other}}
      end
    end
  end

  # `:contingency` has no meaning on the Ambiente Nacional.
  defp an_opts(opts), do: opts |> Map.delete(:contingency) |> Map.put(:uf, "AN")

  defp model_from_mod("55"), do: {:ok, 55}
  defp model_from_mod("65"), do: {:ok, 65}
  defp model_from_mod(mod), do: {:error, {:unsupported_model, mod}}

  defp put_supl(signed, 65, opts) do
    qr_opts = opts |> Map.take([:qr_code_version, :csc, :csc_id]) |> Map.to_list()
    NFCe.put_supl(signed, opts.uf, opts.environment, qr_opts)
  end

  defp put_supl(signed, 55, _opts), do: {:ok, signed}

  # The model an access key carries: positions 21 and 22 (0-based 20).
  defp key_model(ch_nfe) do
    case binary_part(ch_nfe, 20, 2) do
      "55" -> {:ok, 55}
      "65" -> {:ok, 65}
      mod -> {:error, {:unsupported_model, mod}}
    end
  end

  # `:model` selects the endpoints of the services that take no document.
  defp model(opts) do
    case Map.get(opts, :model, 55) do
      model when model in [55, 65] -> {:ok, model}
      other -> {:error, {:unsupported_model, other}}
    end
  end

  # Synchronous, because this library sends one document per lote and SEFAZ
  # rejects an asynchronous request for a single-document batch outright
  # (cStat 452). Asynchronous only makes sense for a real batch, which is not
  # what v1 builds; `sync: false` is kept for a caller who assembles one.
  defp ind_sinc(opts), do: if(Map.get(opts, :sync, true), do: 1, else: 0)

  @doc """
  `NFeRetAutorizacao4` for a receipt (`n_rec`).

  What an asynchronous `authorize/1` leaves to be collected. `cStat` 105 means
  the batch is still processing and the caller should ask again; 104 means it
  finished, and the document's own outcome is read from the nested protocol.

  `:model` (55 by default, or 65) selects the endpoints.
  """
  @spec authorization_result(map()) :: {:ok, Result.t()} | {:error, term()}
  def authorization_result(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:n_rec, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         {:ok, model} <- model(opts),
         {:ok, url} <- Endpoints.url(opts.uf, opts.environment, :nfe_ret_autorizacao, model),
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

  `:model` (55 by default, or 65) selects the NF-e or the NFC-e authorizer.

  `:contingency` (`:svc_an` or `:svc_rs`) asks the SVC instead. See
  `consult_protocol/1` for the rules, which are the same here.
  """
  @spec service_status(map()) :: {:ok, Result.t()} | {:error, term()}
  def service_status(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         {:ok, model} <- model(opts),
         {:ok, url} <- route(opts, :nfe_status_servico, model),
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
  `NFeConsultaCadastro` (`CadConsultaCadastro4`): the state taxpayer registry.

  `:uf` is the UF whose registry is consulted, and also selects the endpoint.
  Exactly one filter is required: `:tax_id` (CPF, or CNPJ including the
  alphanumeric one; shape-checked like everywhere else) or `:ie`, a state
  registration of 2 to 14 digits (shape only).

  Neither filter, or both, is `{:error, {:invalid_filter, :missing | :ambiguous}}`;
  a malformed state registration is `{:error, :invalid_ie}`. A UF whose
  authorizer does not offer the service (AM, and MA through SVAN) is
  `{:error, {:unknown_endpoint, uf, :nfe_consulta_cadastro}}`.

  `cStat` 111 and 112 carry one or several records, and a rejection such as 259
  (not registered) is still `{:ok, lookup}` with `taxpayers: []`. See
  `SefazNfe.TaxpayerLookup`.
  """
  @spec consult_taxpayer(map()) :: {:ok, SefazNfe.TaxpayerLookup.t()} | {:error, term()}
  def consult_taxpayer(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         {:ok, filter} <- taxpayer_filter(opts),
         {:ok, url} <- Endpoints.url(opts.uf, opts.environment, :nfe_consulta_cadastro),
         uf = opts.uf |> to_string() |> String.upcase(),
         message = Envelope.consult_taxpayer(uf, filter),
         {:ok, envelope} <- Envelope.wrap(:nfe_consulta_cadastro, message),
         operation = Endpoints.operation(uf, :nfe_consulta_cadastro),
         {:ok, body} <-
           call(url, envelope, opts, :nfe_consulta_cadastro, operation: operation) do
      TaxpayerLookup.parse(body)
    end
  end

  defp taxpayer_filter(opts) do
    case {Map.fetch(opts, :tax_id), Map.fetch(opts, :ie)} do
      {:error, :error} ->
        {:error, {:invalid_filter, :missing}}

      {{:ok, _tax_id}, {:ok, _ie}} ->
        {:error, {:invalid_filter, :ambiguous}}

      {{:ok, tax_id}, :error} ->
        with :ok <- validate_tax_id(tax_id), do: {:ok, {:tax_id, tax_id}}

      {:error, {:ok, ie}} ->
        with :ok <- validate_ie(ie), do: {:ok, {:ie, ie}}
    end
  end

  defp validate_ie(ie) when is_binary(ie) do
    if String.match?(ie, ~r/^\d{2,14}$/), do: :ok, else: {:error, :invalid_ie}
  end

  defp validate_ie(_), do: {:error, :invalid_ie}

  @doc """
  `NFeConsultaProtocolo4` by 44-digit access key.

  The idempotent way back after a crash between a receipt and a protocol: ask
  SEFAZ what it did with a document instead of sending the batch again.

  The model comes from the key, so an NFC-e is asked of the NFC-e authorizer.

  ## `:contingency`

  Optional, `:svc_an` or `:svc_rs`: ask that SVC instead of the origin. Absent
  means the UF's own authorizer, exactly as before. It must be the SVC that
  serves `:uf`, else `{:error, {:wrong_contingency, uf, svc}}` naming the one
  that does; NFC-e has no SVC (`{:error, {:unsupported_for_model, 65}}`).

  It is never inferred from the key's `tpEmis` digit (AD-005): once contingency
  ends, documents issued under SVC are handled at the origin, so only the
  caller knows which authorizer holds the document now. `cancel/1`, `cce/1` and
  `service_status/1` take the same option with the same rules.
  """
  @spec consult_protocol(map()) :: {:ok, Result.t()} | {:error, term()}
  def consult_protocol(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:ch_nfe, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_ch_nfe(opts.ch_nfe),
         {:ok, model} <- key_model(opts.ch_nfe),
         {:ok, url} <- route(opts, :nfe_consulta_protocolo, model),
         message = Envelope.consult_protocol(opts.ch_nfe, Envelope.tp_amb(opts.environment)),
         {:ok, envelope} <- Envelope.wrap(:nfe_consulta_protocolo, message),
         {:ok, body} <- call(url, envelope, opts, :nfe_consulta_protocolo) do
      Result.parse(body)
    end
  end

  @doc """
  Event 110111, cancelling an authorized NF-e via `NFeRecepcaoEvento4`.

  Needs the protocol the authorization returned, and a justification of at
  least 15 characters as the MOC requires. The model comes from the key, so an
  NFC-e is cancelled at the NFC-e authorizer. Takes the optional `:contingency`
  described in `consult_protocol/1`.
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
         :ok <- validate_justification(opts.justification),
         {:ok, model} <- key_model(opts.ch_nfe) do
      send_event(opts, &Events.cancel/1, model)
    end
  end

  @doc """
  Event 110110, the Carta de Correção Eletrônica, via `NFeRecepcaoEvento4`.

  `:sequence` numbers the correction; each one replaces the previous text
  rather than adding to it.

  NFC-e has no Carta de Correção: a model 65 key is
  `{:error, {:unsupported_for_model, 65}}`. Takes the optional `:contingency`
  described in `consult_protocol/1`.
  """
  @spec cce(map()) :: {:ok, Result.t()} | {:error, term()}
  def cce(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:ch_nfe, :correction, :tax_id, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_ch_nfe(opts.ch_nfe),
         :ok <- validate_tax_id(opts.tax_id),
         :ok <- validate_justification(opts.correction),
         {:ok, 55} <- cce_model(opts.ch_nfe) do
      send_event(opts, &Events.correction/1, 55)
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
      |> an_opts()
      |> send_event(&Events.manifestation(type, &1), 55)
    end
  end

  @doc """
  Event 110140, the EPEC (Evento Prévio de Emissão em Contingência), for an
  NF-e model 55.

  `:xml` is the NF-e issued with `tpEmis` 4, signed or not. It is read and never
  modified; every value the event carries (`chNFe`, `cUF`, `dhEmi`, `tpNF`, the
  emitter's `IE`, the recipient's `UF`, document and `IE`, `vNF`, `vICMS`,
  `vST`) is copied from it. `:verAplic` defaults to its `verProc`: pass
  `:ver_aplic` to override. `:id_lote` is optional.

  EPEC is processed by the Ambiente Nacional (`cOrgao` 91, no `:uf` needed),
  sequence 1, authored by the emitter, and signed on `infEvento` like every
  event. SEFAZ answers `cStat` 136 with the protocol (`:n_prot`) and the
  registration time (`:dh_reg_evento`).

  Refused before the network: a model other than 55
  (`{:unsupported_for_model, 65}`), a document that is not `tpEmis` 4
  (`{:not_epec_document, tp_emis}`), no recipient (`{:epec, :missing_dest}`) and
  an access key whose UF is not `cUF`
  (`{:epec, {:ch_nfe_uf_mismatch, key_uf, c_uf}}`).

  ## What this does not do

  Choosing contingency is the caller's (AD-005); nothing here switches to it. The
  caller also owns the rest of the flow: the DANFE has to carry the EPEC notice,
  and the NF-e itself has to be transmitted to its **origin** authorizer, keeping
  `tpEmis` 4, within 168 hours (`authorize/1` routes a `tpEmis` 4 document there).
  """
  @spec epec(map()) :: {:ok, Result.t()} | {:error, term()}
  def epec(opts) when is_map(opts) do
    with :ok <- require_keys(opts, [:xml, :cert, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- environment_matches_xml(opts.environment, opts.xml),
         {:ok, facts} <- EPEC.extract(opts.xml, ver_aplic: Map.get(opts, :ver_aplic)),
         :ok <- validate_ch_nfe(facts.ch_nfe),
         :ok <- validate_tax_id(facts.tax_id) do
      opts
      |> an_opts()
      |> Map.merge(%{ch_nfe: facts.ch_nfe, tax_id: facts.tax_id, epec: facts.epec})
      |> send_event(&Events.epec/1, 55)
    end
  end

  defp cce_model(ch_nfe) do
    case key_model(ch_nfe) do
      {:ok, 65} -> {:error, {:unsupported_for_model, 65}}
      other -> other
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

  defp send_event(opts, build, model) do
    with {:ok, url} <- route(opts, :nfe_recepcao_evento, model),
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
  defaults to 55 and `:year` to the current one; it is the `mod` of the voided
  range and also selects the endpoints, so 65 voids NFC-e numbers at the NFC-e
  authorizer.
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
         {:ok, model} <- model(opts),
         {:ok, url} <- Endpoints.url(opts.uf, opts.environment, :nfe_inutilizacao, model),
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

  # `extra` carries per-call transport options; `operation:` is the one that
  # makes the SOAP action differ per authorizer (NFeConsultaCadastro only).
  defp call(url, envelope, opts, service, extra \\ []) do
    SOAP.isolated_call(
      url,
      envelope,
      opts.cert,
      [
        uf: to_string(opts.uf),
        service: service,
        timeout: Map.get(opts, :timeout, to_timeout(second: 30)),
        connect_timeout: Map.get(opts, :connect_timeout, to_timeout(second: 10)),
        tls_options: Map.get(opts, :tls_options, [])
      ] ++ extra
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
