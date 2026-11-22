defmodule SefazNfe.CTe do
  @moduledoc """
  CT-e (modelo 57) and CT-e OS (modelo 67) transport, layout 4.00.

  The facade mirrors `SefazNfe`: every operation takes one map, is wrapped in
  the `[:sefaz_nfe, :operation]` telemetry span (operation atoms `:cte_*`) and
  goes through `SefazNfe.Transport` and so through the circuit breaker and
  `SefazNfe.SOAP.isolated_call/4`. The authorizer is per model, not per UF (BA
  is SVRS for CT-e, PE is SVSP); see `SefazNfe.Endpoints`.

  | Function | Service | Notes |
  |----------|---------|-------|
  | `authorize/1` | `CTeRecepcaoSincV4` (57), `CTeRecepcaoOSV4` (67) | sync; no receipt step |
  | `consult/1` | `CTeConsultaV4` | by access key |
  | `service_status/1` | `CTeStatusServicoV4` | |
  | `cancel/1` | `CTeRecepcaoEventoV4` | 110111 |
  | `cce/1` | `CTeRecepcaoEventoV4` | 110110, structured corrections |
  | `delivery_proof/1`, `cancel_delivery_proof/1` | `CTeRecepcaoEventoV4` | 110180, 110181 (model 57) |
  | `delivery_failure/1`, `cancel_delivery_failure/1` | `CTeRecepcaoEventoV4` | 110190, 110191 (model 57) |

  Results are `SefazNfe.Result`, with two CT-e differences. The access key is in
  `:ch_nfe`, whichever the document (`chCTe` here); and the status comes from
  `SefazNfe.CStat.classify/2`, because 678 is "Consumo Indevido" for CT-e. The
  processed documents are built by `SefazNfe.CTe.Proc` and carried in `:xml`.

  ## What goes on the wire

  Only the authorization is compressed: `cteDadosMsg` holds the signed CT-e or
  CT-e OS itself (no `enviCTe`, no XML declaration), gzip-compressed and
  Base64-encoded, as NFePHP's `sefazEnviaCTe` does. Consultation, status and
  events go as plain XML, and an event is the `eventoCTe` alone (no `envEvento`
  and no `idLote`). No `cteCabecMsg` header is sent: it is obsolete from layout
  4.00 and the 4.00 services do not ask for it.

  ## Contingency

  Contingency is the caller's choice (AD-005): nothing here falls back to it,
  and no XML is composed, so the ERP rebuilds the document with the new `tpEmis`
  and `authorize/1` routes on it:

    * `1` goes to the UF's own authorizer;
    * `7` goes to SVC-RS and `8` to SVC-SP (the MOC's codes), but only when that
      SVC is the one that serves `:uf` (`SefazNfe.Endpoints.contingency_for/2`);
      otherwise `{:error, {:wrong_contingency, uf, svc}}`, where `svc` is the
      SVC that does serve it;
    * `3` (NFF), `4` (EPEC) and `5` (FS-DA) are
      `{:error, {:unsupported, {:tp_emis, n}}}`: 4 and 5 need a QR code
      signed with the certificate (`&sign=`), which is not generated.

  Unlike NF-e, the CT-e MOC does not ask for `dhCont`/`xJust` under SVC: rule
  G008 (rejeicao 586) says they must NOT be informed unless `tpEmis` is 5. They
  are neither required nor refused here; SEFAZ is the one that checks.

  The other operations take an optional `:contingency` (`:svc_sp` or
  `:svc_rs`) with the same rules (`SefazNfe.consult_protocol/1` documents them
  for NF-e). It is never inferred from the key's `tpEmis` digit.
  """

  alias SefazNfe.Builder
  alias SefazNfe.CStat
  alias SefazNfe.CTe.Events
  alias SefazNfe.CTe.Proc
  alias SefazNfe.CTe.Supl
  alias SefazNfe.Endpoints
  alias SefazNfe.Result
  alias SefazNfe.Signer
  alias SefazNfe.SOAP.Envelope
  alias SefazNfe.Telemetry
  alias SefazNfe.XML

  import SefazNfe.Transport, only: [call: 4, require_keys: 2, validate_environment: 1]

  @cte_ns "http://www.portalfiscal.inf.br/cte"
  @tp_amb ~r|<tpAmb>([12])</tpAmb>|
  @ch_cte ~r/^\d{6}[A-Z0-9]{12}\d{26}$/
  @ch_cte_in_body ~r|<chCTe>(\d{6}[A-Z0-9]{12}\d{26})</chCTe>|
  @protocol ~r/^\d{15}$/

  @event_keys [:ch_cte, :tax_id, :cert, :uf, :environment]

  # -- authorization ---------------------------------------------------------

  @doc """
  Sign, add the QR code and send a CT-e or CT-e OS to `CTeRecepcaoSincV4` or
  `CTeRecepcaoOSV4`.

  The document is `:xml` (signed or not) or `:cte`, a map for
  `SefazNfe.Builder.build_cte/2` (`ide.mod` 57, the default) or
  `build_cte_os/2` (`ide.mod` 67); exactly one of them. A map that does not
  build is `{:error, {:invalid_cte, errors}}`. The model is read from `<mod>`
  and anything but 57 and 67 is `{:error, {:unsupported_model, mod}}`.

  The pipeline is validate, sign `infCte`, add `infCTeSupl` with `qrCodCTe`
  (`SefazNfe.CTe.Supl`), compress, POST, parse. `tpAmb` is checked against
  `:environment` before anything is sent. `tpEmis` routes as the moduledoc
  describes. XSD validation of the CT-e is not done here: `SefazNfe.Schema`
  holds one directory of NF-e schemas, and SEFAZ answers 215 with a schema
  failure anyway.

  The result carries `:signed_xml` (what was sent, QR code included) and, once
  SEFAZ answered with a protocol the document may carry (see
  `SefazNfe.CTe.Proc.cte_proc/2`), `:xml` holding the `cteProc` or `cteOSProc`
  to archive. Store `:signed_xml` even when the answer is a transport error:
  SEFAZ may have processed the document, and `consult/1` is the way to find out
  before sending it again.
  """
  @spec authorize(map()) :: {:ok, Result.t()} | {:error, term()}
  def authorize(opts) when is_map(opts), do: Telemetry.span(:cte_authorize, opts, &do_authorize/1)

  defp do_authorize(opts) do
    with {:ok, opts} <- document_source(opts),
         :ok <- require_keys(opts, [:xml, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- environment_matches_xml(opts.environment, opts.xml),
         {:ok, doc} <- XML.parse(opts.xml),
         {:ok, model} <- model_from_mod(XML.text(doc, "mod")),
         {service, root} = send_service(model),
         {:ok, url} <- emission_url(opts, model, service, XML.text(doc, "tpEmis")),
         {:ok, signed} <- Signer.sign(opts.xml, opts.cert, "infCte", root),
         {:ok, signed} <- Supl.put(signed, opts.uf, opts.environment),
         {:ok, envelope} <- Envelope.wrap(service, compress(signed)),
         {:ok, body} <- call(url, envelope, opts, service),
         {:ok, result} <- Result.parse(body) do
      result = finish(result, body, model)
      {:ok, %{result | signed_xml: signed, xml: processed(Proc.cte_proc(signed, body))}}
    end
  end

  # The document is either `:xml` or `:cte`, the map the builder takes. A map
  # that does not build never reaches the network.
  defp document_source(%{xml: _, cte: _}), do: {:error, {:conflicting_keys, [:xml, :cte]}}

  defp document_source(%{cte: cte} = opts) when is_map(cte) do
    with {:ok, builder} <- builder(cte) do
      case builder.(cte) do
        {:ok, %{xml: xml}} -> {:ok, opts |> Map.delete(:cte) |> Map.put(:xml, xml)}
        {:error, errors} -> {:error, {:invalid_cte, errors}}
      end
    end
  end

  defp document_source(opts), do: {:ok, opts}

  defp builder(cte) do
    case cte |> Map.get(:ide, %{}) |> Map.get(:mod) do
      mod when mod in [nil, 57, "57"] -> {:ok, &Builder.build_cte/1}
      mod when mod in [67, "67"] -> {:ok, &Builder.build_cte_os/1}
      mod -> {:error, {:unsupported_model, mod}}
    end
  end

  defp model_from_mod("57"), do: {:ok, 57}
  defp model_from_mod("67"), do: {:ok, 67}
  defp model_from_mod(mod), do: {:error, {:unsupported_model, mod}}

  # The service a model sends through, and the element its signature goes in.
  defp send_service(57), do: {:cte_recepcao_sinc, "CTe"}
  defp send_service(67), do: {:cte_recepcao_os, "CTeOS"}

  # 1 is normal; 7 and 8 are SVC-RS and SVC-SP, and only the SVC that serves
  # the emitter UF takes it. An absent tpEmis is the XSD's to refuse (it is
  # mandatory), not a routing decision.
  defp emission_url(opts, model, service, tp_emis) when tp_emis in [nil, "1"],
    do: Endpoints.url(opts.uf, opts.environment, service, model)

  defp emission_url(opts, model, service, "7"),
    do: route(Map.put(opts, :contingency, :svc_rs), service, model)

  defp emission_url(opts, model, service, "8"),
    do: route(Map.put(opts, :contingency, :svc_sp), service, model)

  defp emission_url(_opts, _model, _service, tp_emis),
    do: {:error, {:unsupported, {:tp_emis, tp_emis}}}

  # `base64(gzip(xml))`: the declaration is not part of what NFePHP sends.
  defp compress(signed) do
    signed |> strip_declaration() |> :zlib.gzip() |> Base.encode64()
  end

  # -- consult and status ----------------------------------------------------

  @doc """
  `CTeConsultaV4` (`consSitCTe`) by 44-character access key.

  The idempotent way back after a failure between the send and the answer: ask
  SEFAZ what it did with the document instead of sending it again. The model
  comes from the key. Takes the optional `:contingency` described in the
  moduledoc. The result carries the protocol (`:n_prot`) and, for a document
  SEFAZ has, `cStat` 100 (`:authorized`), 101 (`:cancelled`) or 110
  (`:denied`); 217 (not found) is a rejection.
  """
  @spec consult(map()) :: {:ok, Result.t()} | {:error, term()}
  def consult(opts) when is_map(opts), do: Telemetry.span(:cte_consult, opts, &do_consult/1)

  defp do_consult(opts) do
    with :ok <- require_keys(opts, [:ch_cte, :cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_ch_cte(opts.ch_cte),
         {:ok, model} <- key_model(opts.ch_cte),
         {:ok, url} <- route(opts, :cte_consulta, model),
         message = consult_message(opts.ch_cte, Envelope.tp_amb(opts.environment)),
         {:ok, envelope} <- Envelope.wrap(:cte_consulta, message),
         {:ok, body} <- call(url, envelope, opts, :cte_consulta),
         {:ok, result} <- Result.parse(body) do
      {:ok, finish(result, body, model)}
    end
  end

  defp consult_message(ch_cte, tp_amb) do
    ~s(<consSitCTe xmlns="#{@cte_ns}" versao="4.00">) <>
      ~s(<tpAmb>#{tp_amb}</tpAmb><xServ>CONSULTAR</xServ><chCTe>#{ch_cte}</chCTe>) <>
      ~s(</consSitCTe>)
  end

  @doc """
  `CTeStatusServicoV4` for one UF.

  Options: `:cert`, `:uf` and `:environment`, and `:model` (57 by default, or
  67). `cStat` 107 is `:in_operation`; 108 and 109 are `:retryable`, and all
  arrive as `{:ok, result}` because SEFAZ answered. See `SefazNfe.CStat`. Takes
  the optional `:contingency` described in the moduledoc.
  """
  @spec service_status(map()) :: {:ok, Result.t()} | {:error, term()}
  def service_status(opts) when is_map(opts) do
    Telemetry.span(:cte_service_status, opts, &do_service_status/1)
  end

  defp do_service_status(opts) do
    with :ok <- require_keys(opts, [:cert, :uf, :environment]),
         :ok <- validate_environment(opts.environment),
         {:ok, model} <- model(opts),
         {:ok, url} <- route(opts, :cte_status_servico, model),
         {:ok, uf_code} <- Endpoints.uf_code(opts.uf),
         message = Envelope.status_service_cte(uf_code, Envelope.tp_amb(opts.environment)),
         {:ok, envelope} <- Envelope.wrap(:cte_status_servico, message),
         {:ok, body} <- call(url, envelope, opts, :cte_status_servico),
         {:ok, result} <- Result.parse(body) do
      {:ok, finish(result, body, model)}
    end
  end

  defp model(opts) do
    case Map.get(opts, :model, 57) do
      model when model in [57, 67] -> {:ok, model}
      other -> {:error, {:unsupported_model, other}}
    end
  end

  # -- events ----------------------------------------------------------------

  @doc """
  Event 110111, cancelling an authorized CT-e or CT-e OS.

  Options: `:ch_cte`, `:n_prot` (the authorization's protocol), `:justification`
  (15 to 255 characters), `:tax_id` (the author: the emitter's CNPJ or CPF),
  `:cert`, `:uf`, `:environment`; `:sequence` (1 by default) and `:timestamp`.

  Like every event here, the result carries `:signed_xml` (the `eventoCTe` sent)
  and, once SEFAZ registered it (`cStat` 134, 135 or 136, and 155 for a
  cancellation), `:xml` holding the `procEventoCTe`.
  `SefazNfe.CTe.Proc.cte_cancel_register/2` appends the cancellation to the
  `cteProc`.
  """
  @spec cancel(map()) :: {:ok, Result.t()} | {:error, term()}
  def cancel(opts) when is_map(opts), do: Telemetry.span(:cte_cancel, opts, &do_cancel/1)

  defp do_cancel(opts) do
    with :ok <- require_keys(opts, [:n_prot, :justification | @event_keys]),
         {:ok, model} <- validate_event(opts),
         :ok <- validate_protocol(opts.n_prot),
         :ok <- validate_justification(opts.justification) do
      send_event(opts, &Events.cancel/1, model)
    end
  end

  @doc """
  Event 110110, the structured Carta de Correcao.

  `:corrections` is a non-empty list of maps with `:grupo_alterado` (the group,
  such as `"ide"`), `:campo_alterado` (the field) and `:valor_alterado` (the new
  value), and `:nro_item_alterado` (1-based, when the field is in a list).
  Lengths follow the XSD: 20, 20 and 500 characters. `:sequence` numbers the
  correction (1 by default); `xCondUso` is the fixed legal text. Anything wrong
  is `{:error, {:invalid_corrections, reason}}` before the network.
  """
  @spec cce(map()) :: {:ok, Result.t()} | {:error, term()}
  def cce(opts) when is_map(opts), do: Telemetry.span(:cte_cce, opts, &do_cce/1)

  defp do_cce(opts) do
    with :ok <- require_keys(opts, [:corrections | @event_keys]),
         {:ok, model} <- validate_event(opts),
         :ok <- validate_corrections(opts.corrections) do
      send_event(opts, &Events.correction/1, model)
    end
  end

  @doc """
  Event 110180, the comprovante de entrega (model 57 only).

  Options: `:n_prot`, `:dh_entrega` (a `DateTime`, or ISO 8601 text with an
  offset), `:n_doc` and `:x_nome` (who received it), `:image` (the proof's
  bytes: a signature, a photo), plus the event keys of `cancel/1`; and
  optionally `:latitude` and `:longitude` (a float, or text in the XSD's six
  decimals), `:ch_nfes` (the NF-e keys delivered, for a normal service) and
  `:dh_hash`.

  `hashEntrega` is computed here from `:image`: base64 of the SHA-1 of the
  access key followed by the base64 of the image
  (`SefazNfe.CTe.Events.delivery_hash/2`). The image itself is not sent: it is
  the author's to keep.
  """
  @spec delivery_proof(map()) :: {:ok, Result.t()} | {:error, term()}
  def delivery_proof(opts) when is_map(opts),
    do: Telemetry.span(:cte_delivery_proof, opts, &do_delivery_proof/1)

  defp do_delivery_proof(opts) do
    with :ok <-
           require_keys(opts, [:n_prot, :dh_entrega, :n_doc, :x_nome, :image | @event_keys]),
         {:ok, 57} <- validate_cargo_event(opts),
         :ok <- validate_protocol(opts.n_prot),
         :ok <- validate_image(opts.image) do
      send_event(opts, &Events.delivery_proof/1, 57)
    end
  end

  @doc """
  Event 110181, cancelling a comprovante de entrega (model 57 only).

  `:n_prot` is the CT-e's protocol and `:n_prot_ce` the delivery proof event's;
  `:sequence` is the cancelled proof's sequence (1 by default).
  """
  @spec cancel_delivery_proof(map()) :: {:ok, Result.t()} | {:error, term()}
  def cancel_delivery_proof(opts) when is_map(opts),
    do: Telemetry.span(:cte_cancel_delivery_proof, opts, &do_cancel_delivery_proof/1)

  defp do_cancel_delivery_proof(opts) do
    with :ok <- require_keys(opts, [:n_prot, :n_prot_ce | @event_keys]),
         {:ok, 57} <- validate_cargo_event(opts),
         :ok <- validate_protocol(opts.n_prot),
         :ok <- validate_protocol(opts.n_prot_ce) do
      send_event(opts, &Events.cancel_delivery_proof/1, 57)
    end
  end

  @doc """
  Event 110190, the insucesso na entrega (model 57 only).

  Options: `:n_prot`, `:dh_tentativa_entrega`, `:tp_motivo` (1 recebedor nao
  encontrado, 2 recusa do recebedor, 3 endereco inexistente, 4 outros), plus the
  event keys of `cancel/1`; optionally `:n_tentativa`, `:x_just_motivo` (15 to
  256 characters, required with motivo 4), `:latitude`, `:longitude`, `:image`
  (hashed into `hashTentativaEntrega` like the delivery proof's; without it the
  hash group is left out, as the XSD allows), `:dh_hash` and `:ch_nfes`.
  """
  @spec delivery_failure(map()) :: {:ok, Result.t()} | {:error, term()}
  def delivery_failure(opts) when is_map(opts),
    do: Telemetry.span(:cte_delivery_failure, opts, &do_delivery_failure/1)

  defp do_delivery_failure(opts) do
    with :ok <- require_keys(opts, [:n_prot, :dh_tentativa_entrega, :tp_motivo | @event_keys]),
         {:ok, 57} <- validate_cargo_event(opts),
         :ok <- validate_protocol(opts.n_prot),
         :ok <- validate_motive(opts) do
      send_event(opts, &Events.delivery_failure/1, 57)
    end
  end

  @doc """
  Event 110191, cancelling an insucesso na entrega (model 57 only).

  `:n_prot` is the CT-e's protocol and `:n_prot_ie` the failure event's.
  """
  @spec cancel_delivery_failure(map()) :: {:ok, Result.t()} | {:error, term()}
  def cancel_delivery_failure(opts) when is_map(opts),
    do: Telemetry.span(:cte_cancel_delivery_failure, opts, &do_cancel_delivery_failure/1)

  defp do_cancel_delivery_failure(opts) do
    with :ok <- require_keys(opts, [:n_prot, :n_prot_ie | @event_keys]),
         {:ok, 57} <- validate_cargo_event(opts),
         :ok <- validate_protocol(opts.n_prot),
         :ok <- validate_protocol(opts.n_prot_ie) do
      send_event(opts, &Events.cancel_delivery_failure/1, 57)
    end
  end

  defp send_event(opts, build, model) do
    with {:ok, url} <- route(opts, :cte_recepcao_evento, model),
         {:ok, uf_code} <- Endpoints.uf_code(opts.uf),
         event = build.(event_opts(opts, uf_code)),
         {:ok, signed} <- Signer.sign(event, opts.cert, "infEvento", "eventoCTe"),
         {:ok, envelope} <- Envelope.wrap(:cte_recepcao_evento, strip_declaration(signed)),
         {:ok, body} <- call(url, envelope, opts, :cte_recepcao_evento),
         {:ok, result} <- Result.parse(body) do
      result = finish(result, body, model)
      {:ok, %{result | signed_xml: signed, xml: processed(Proc.cte_event_proc(signed, body))}}
    end
  end

  defp event_opts(opts, uf_code) do
    Map.merge(opts, %{uf_code: uf_code, tp_amb: Envelope.tp_amb(opts.environment)})
  end

  # -- routing ---------------------------------------------------------------

  # Where `service` is called for `opts.uf`: its own authorizer, or the SVC the
  # caller names in `:contingency` (AD-005: never inferred). Only the SVC that
  # serves the UF is accepted; the error names the SVC that does.
  defp route(opts, service, model) do
    case Map.get(opts, :contingency) do
      nil -> Endpoints.url(opts.uf, opts.environment, service, model)
      svc -> svc_route(svc, opts, service, model)
    end
  end

  defp svc_route(svc, _opts, _service, _model) when svc not in [:svc_sp, :svc_rs],
    do: {:error, {:invalid_contingency, svc}}

  defp svc_route(svc, opts, service, model) do
    with {:ok, expected} <- Endpoints.contingency_for(opts.uf, model) do
      case expected do
        ^svc ->
          Endpoints.contingency_url(svc, opts.environment, service, model)

        other ->
          {:error, {:wrong_contingency, opts.uf |> to_string() |> String.upcase(), other}}
      end
    end
  end

  # -- results ---------------------------------------------------------------

  # `Result` reads NF-e names. For CT-e the key is `chCTe`, which goes in
  # `:ch_nfe`, and the status is the CT-e classification.
  defp finish(result, body, model) do
    %{
      result
      | status: CStat.classify(result.c_stat, model),
        ch_nfe: result.ch_nfe || ch_cte_in(body)
    }
  end

  defp ch_cte_in(body) do
    case Regex.run(@ch_cte_in_body, body, capture: :all_but_first) do
      [key] -> key
      nil -> nil
    end
  end

  # `Result.xml` is the processed document once SEFAZ accepted it, else `nil`.
  defp processed({:ok, xml}), do: xml
  defp processed({:error, _reason}), do: nil

  # -- validation ------------------------------------------------------------

  # Shared by every event: environment, key, author and the model the key says.
  defp validate_event(opts) do
    with :ok <- validate_environment(opts.environment),
         :ok <- validate_ch_cte(opts.ch_cte),
         :ok <- validate_tax_id(opts.tax_id) do
      key_model(opts.ch_cte)
    end
  end

  # The delivery events are CT-e (model 57) only, per the MOC.
  defp validate_cargo_event(opts) do
    case validate_event(opts) do
      {:ok, 57} -> {:ok, 57}
      {:ok, model} -> {:error, {:unsupported_for_model, model}}
      error -> error
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

  defp validate_ch_cte(ch) when is_binary(ch) do
    if Regex.match?(@ch_cte, ch), do: :ok, else: {:error, :invalid_ch_cte}
  end

  defp validate_ch_cte(_), do: {:error, :invalid_ch_cte}

  # The model an access key carries: positions 21 and 22 (0-based 20).
  defp key_model(ch_cte) do
    case binary_part(ch_cte, 20, 2) do
      "57" -> {:ok, 57}
      "67" -> {:ok, 67}
      mod -> {:error, {:unsupported_model, mod}}
    end
  end

  defp validate_tax_id(id) when is_binary(id) and byte_size(id) == 11 do
    if String.match?(id, ~r/^\d{11}$/), do: :ok, else: {:error, :invalid_tax_id}
  end

  defp validate_tax_id(id) when is_binary(id) and byte_size(id) == 14 do
    if String.match?(id, ~r/^[A-Z0-9]{12}\d{2}$/), do: :ok, else: {:error, :invalid_tax_id}
  end

  defp validate_tax_id(_), do: {:error, :invalid_tax_id}

  defp validate_protocol(n_prot) when is_binary(n_prot) do
    if Regex.match?(@protocol, n_prot), do: :ok, else: {:error, :invalid_n_prot}
  end

  defp validate_protocol(_), do: {:error, :invalid_n_prot}

  # TJust: 15 to 255 characters.
  defp validate_justification(text) when is_binary(text) do
    case String.length(text) do
      length when length < 15 -> {:error, :justification_too_short}
      length when length > 255 -> {:error, :justification_too_long}
      _ok -> :ok
    end
  end

  defp validate_justification(_), do: {:error, :justification_too_short}

  defp validate_image(image) when is_binary(image) and image != "", do: :ok
  defp validate_image(_), do: {:error, :invalid_image}

  # 1 to 3 need no text; 4 (outros) needs a justification of 15 to 256.
  defp validate_motive(opts) do
    case to_string(opts.tp_motivo) do
      motive when motive in ["1", "2", "3"] -> :ok
      "4" -> validate_motive_text(Map.get(opts, :x_just_motivo))
      _other -> {:error, :invalid_tp_motivo}
    end
  end

  defp validate_motive_text(text) when is_binary(text) do
    if String.length(text) in 15..256//1, do: :ok, else: {:error, :invalid_x_just_motivo}
  end

  defp validate_motive_text(_), do: {:error, :invalid_x_just_motivo}

  defp validate_corrections([_ | _] = corrections) do
    corrections
    |> Enum.with_index(1)
    |> Enum.find_value(:ok, fn {correction, index} ->
      case correction_problem(correction) do
        nil -> nil
        problem -> {:error, {:invalid_corrections, {index, problem}}}
      end
    end)
  end

  defp validate_corrections(_), do: {:error, {:invalid_corrections, :empty}}

  @correction_limits [grupo_alterado: 20, campo_alterado: 20, valor_alterado: 500]

  defp correction_problem(correction) when is_map(correction) do
    Enum.find_value(@correction_limits, &field_problem(correction, &1)) ||
      item_problem(Map.get(correction, :nro_item_alterado))
  end

  defp correction_problem(_), do: :not_a_map

  defp field_problem(correction, {field, max}) do
    case Map.get(correction, field) do
      value when is_binary(value) and byte_size(value) > 0 ->
        if String.length(value) > max, do: {:too_long, field}

      _missing ->
        {:missing, field}
    end
  end

  defp item_problem(nil), do: nil
  defp item_problem(n) when is_integer(n) and n in 1..99, do: nil
  defp item_problem(_), do: {:invalid, :nro_item_alterado}

  defp strip_declaration(xml), do: String.replace(xml, ~r/^\s*<\?xml[^>]*\?>/, "")
end
