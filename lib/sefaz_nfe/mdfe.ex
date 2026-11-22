defmodule SefazNfe.MDFe do
  @moduledoc """
  MDF-e (modelo 58) transport, layout 3.00.

  SVRS authorizes MDF-e for every UF, so `:uf` selects nothing but the circuit
  breaker and the telemetry tag. Every call goes through
  `SefazNfe.SOAP.isolated_call/4`; every answer SEFAZ gave is `{:ok, result}`,
  a rejection included, and only transport failures are `{:error, _}`.

  | Function | Service | Event |
  |----------|---------|-------|
  | `authorize/1` | `MDFeRecepcaoSinc` | |
  | `consult/1` | `MDFeConsulta` | |
  | `service_status/1` | `MDFeStatusServico` | |
  | `pending/1` | `MDFeConsNaoEnc` | |
  | `cancel/1` | `MDFeRecepcaoEvento` | 110111 |
  | `close/1` | `MDFeRecepcaoEvento` | 110112 |
  | `include_driver/1` | `MDFeRecepcaoEvento` | 110114 |
  | `include_dfe/1` | `MDFeRecepcaoEvento` | 110115 |

  Events carry `:signed_xml` (the `eventoMDFe` sent) and, once SEFAZ registered
  them (`cStat` 135 or 136), `:xml` holding the `procEventoMDFe`; see
  `SefazNfe.MDFe.Proc` and `SefazNfe.Proc`. `Result.ch_nfe` holds the `chMDFe`:
  the field is the access key of the document, whatever the model.

  Contingency is the caller's (AD-005) and MDF-e has no SVC: it is the off-line
  `tpEmis` 2, which `authorize/1` accepts and signs the QR code for.
  """

  alias SefazNfe.Builder
  alias SefazNfe.Endpoints
  alias SefazNfe.MDFe.Answer
  alias SefazNfe.MDFe.Events
  alias SefazNfe.MDFe.Messages
  alias SefazNfe.MDFe.Pending
  alias SefazNfe.MDFe.Proc
  alias SefazNfe.MDFe.QRCode
  alias SefazNfe.Result
  alias SefazNfe.Signer
  alias SefazNfe.SOAP.Envelope
  alias SefazNfe.Telemetry
  alias SefazNfe.XML

  import SefazNfe.Transport, only: [call: 4, require_keys: 2, validate_environment: 1]

  @tp_amb ~r|<tpAmb>([12])</tpAmb>|
  @common [:cert, :uf, :environment]

  @doc """
  `MDFeStatusServico`.

  Options: `:cert`, `:uf` and `:environment`. `cStat` 107 is `:in_operation`;
  108 and 109 are `:retryable`. See `SefazNfe.CStat`.
  """
  @spec service_status(map()) :: {:ok, Result.t()} | {:error, term()}
  def service_status(opts) when is_map(opts) do
    Telemetry.span(:mdfe_service_status, opts, &do_service_status/1)
  end

  defp do_service_status(opts) do
    with :ok <- require_keys(opts, @common),
         :ok <- validate_environment(opts.environment),
         {:ok, url} <- url(opts, :mdfe_status_servico),
         message = Envelope.status_service_mdfe(Envelope.tp_amb(opts.environment)),
         {:ok, envelope} <- Envelope.wrap(:mdfe_status_servico, message),
         {:ok, body} <- call(url, envelope, opts, :mdfe_status_servico) do
      Result.parse(body)
    end
  end

  @doc """
  Signs and sends an MDF-e to `MDFeRecepcaoSinc`, which answers in the same call.

  The document is `:xml` (the MDF-e, signed or not) or `:mdfe`, a map for
  `SefazNfe.Builder.build_mdfe/2` (exactly one of them); a map that does not
  build is `{:error, {:invalid_mdfe, errors}}`.

  The pipeline is validate, sign `infMDFe`, add `infMDFeSupl` with the QR code
  (see `SefazNfe.MDFe.QRCode`; a document that has one keeps it), send
  `base64(gzip(MDFe))` and parse `retMDFe`. There is no `SefazNfe.Schema` step:
  `:xmerl_xsd` refuses the signed document (`Reference URI="#MDFe..."` is not an
  `anyURI` to it) and the unsigned one lacks the mandatory `Signature`.

  `tpAmb` against `:environment` is checked before anything is sent, and `<mod>`
  must be 58. `tpEmis` 1 is normal and 2 is off-line contingency (the QR code is
  then signed with the certificate); anything else is
  `{:error, {:unsupported, {:tp_emis, n}}}`.

  The result carries `:signed_xml` (what was sent) and, on `cStat` 100, `:xml`
  holding the `mdfeProc` from `SefazNfe.Proc.mdfe_proc/2`.
  """
  @spec authorize(map()) :: {:ok, Result.t()} | {:error, term()}
  def authorize(opts) when is_map(opts) do
    Telemetry.span(:mdfe_authorize, opts, &do_authorize/1)
  end

  defp do_authorize(opts) do
    with {:ok, opts} <- document_source(opts),
         :ok <- require_keys(opts, [:xml | @common]),
         :ok <- validate_environment(opts.environment),
         :ok <- environment_matches_xml(opts.environment, opts.xml),
         {:ok, doc} <- XML.parse(opts.xml),
         :ok <- check_model(XML.text(doc, "mod")),
         {:ok, url} <- url(opts, :mdfe_recepcao_sinc),
         {:ok, signed} <- Signer.sign(opts.xml, opts.cert, "infMDFe", "MDFe"),
         {:ok, signed} <- QRCode.put_supl(signed, opts.cert, opts.environment),
         {:ok, envelope} <- Envelope.wrap(:mdfe_recepcao_sinc, Messages.send_mdfe(signed)),
         {:ok, body} <- call(url, envelope, opts, :mdfe_recepcao_sinc),
         {:ok, result} <- Answer.parse(body, :protocol) do
      {:ok, %{result | signed_xml: signed, xml: processed(Proc.mdfe_proc(signed, body))}}
    end
  end

  defp document_source(%{xml: _, mdfe: _}), do: {:error, {:conflicting_keys, [:xml, :mdfe]}}

  defp document_source(%{mdfe: mdfe} = opts) do
    case Builder.build_mdfe(mdfe) do
      {:ok, %{xml: xml}} -> {:ok, opts |> Map.delete(:mdfe) |> Map.put(:xml, xml)}
      {:error, errors} -> {:error, {:invalid_mdfe, errors}}
    end
  end

  defp document_source(opts), do: {:ok, opts}

  defp check_model("58"), do: :ok
  defp check_model(mod), do: {:error, {:unsupported_model, mod}}

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

  @doc """
  `MDFeConsulta` by access key (`:ch_mdfe`).

  The idempotent way back after a crash between a send and its answer: ask SEFAZ
  what it did with the MDF-e instead of sending it again. `cStat` is the
  document's situation: 100 `:authorized`, 101 `:cancelled`, 132 `:closed`.
  """
  @spec consult(map()) :: {:ok, Result.t()} | {:error, term()}
  def consult(opts) when is_map(opts), do: Telemetry.span(:mdfe_consult, opts, &do_consult/1)

  defp do_consult(opts) do
    with :ok <- require_keys(opts, [:ch_mdfe | @common]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_ch_mdfe(opts.ch_mdfe),
         {:ok, url} <- url(opts, :mdfe_consulta),
         message = Messages.consult(opts.ch_mdfe, Envelope.tp_amb(opts.environment)),
         {:ok, envelope} <- Envelope.wrap(:mdfe_consulta, message),
         {:ok, body} <- call(url, envelope, opts, :mdfe_consulta) do
      Answer.parse(body, :consult)
    end
  end

  @doc """
  `MDFeConsNaoEnc`: the MDF-e of `:tax_id` (CNPJ or CPF of the emitter) that were
  authorized and not closed.

  `{:ok, %SefazNfe.MDFe.Pending{}}` with `:documents` a list of
  `%{ch_mdfe: key, n_prot: protocol}`: empty, one or many.
  """
  @spec pending(map()) :: {:ok, Pending.t()} | {:error, term()}
  def pending(opts) when is_map(opts), do: Telemetry.span(:mdfe_pending, opts, &do_pending/1)

  defp do_pending(opts) do
    with :ok <- require_keys(opts, [:tax_id | @common]),
         :ok <- validate_environment(opts.environment),
         :ok <- validate_tax_id(opts.tax_id),
         {:ok, url} <- url(opts, :mdfe_consulta_nao_enc),
         message = Messages.pending(opts.tax_id, Envelope.tp_amb(opts.environment)),
         {:ok, envelope} <- Envelope.wrap(:mdfe_consulta_nao_enc, message),
         {:ok, body} <- call(url, envelope, opts, :mdfe_consulta_nao_enc) do
      Pending.parse(body)
    end
  end

  @doc """
  Event 110111, cancelling an authorized MDF-e.

  Needs `:ch_mdfe`, `:n_prot` (from the authorization), `:justification` (15 to
  255 characters) and `:tax_id`, the author (the emitter's CNPJ or CPF).
  """
  @spec cancel(map()) :: {:ok, Result.t()} | {:error, term()}
  def cancel(opts) when is_map(opts), do: Telemetry.span(:mdfe_cancel, opts, &do_cancel/1)

  defp do_cancel(opts) do
    with :ok <- require_keys(opts, [:ch_mdfe, :n_prot, :justification, :tax_id | @common]),
         :ok <- validate_event(opts),
         :ok <- validate_n_prot(opts.n_prot),
         :ok <- validate_justification(opts.justification) do
      send_event(opts, &Events.cancel/1)
    end
  end

  @doc """
  Event 110112, the encerramento: the MDF-e reached where it was going.

  Needs `:ch_mdfe`, `:n_prot`, `:tax_id`, `:dt_enc` (a `Date` or `YYYY-MM-DD`),
  and `:c_uf` and `:c_mun` (IBGE codes of the place of the encerramento).
  `:ind_enc_por_terceiro` (`true`) marks an encerramento by a third party.
  """
  @spec close(map()) :: {:ok, Result.t()} | {:error, term()}
  def close(opts) when is_map(opts), do: Telemetry.span(:mdfe_close, opts, &do_close/1)

  defp do_close(opts) do
    with :ok <-
           require_keys(opts, [:ch_mdfe, :n_prot, :c_uf, :c_mun, :dt_enc, :tax_id | @common]),
         :ok <- validate_event(opts),
         :ok <- validate_n_prot(opts.n_prot),
         :ok <- validate_digits(opts.c_uf, 2, :invalid_c_uf),
         :ok <- validate_digits(opts.c_mun, 7, :invalid_c_mun),
         :ok <- validate_date(opts.dt_enc) do
      send_event(opts, &Events.close/1)
    end
  end

  @doc """
  Event 110114, adding a driver to an MDF-e in transit.

  Needs `:ch_mdfe`, `:tax_id`, `:x_nome` (2 to 60 characters) and `:cpf`.
  `:sequence` numbers the event (1 by default); each driver added to the same
  MDF-e takes the next one. The layout has no protocol field here, so `:n_prot`
  is accepted and not sent.
  """
  @spec include_driver(map()) :: {:ok, Result.t()} | {:error, term()}
  def include_driver(opts) when is_map(opts),
    do: Telemetry.span(:mdfe_include_driver, opts, &do_include_driver/1)

  defp do_include_driver(opts) do
    with :ok <- require_keys(opts, [:ch_mdfe, :x_nome, :cpf, :tax_id | @common]),
         :ok <- validate_event(opts),
         :ok <- validate_text(opts.x_nome, 2..60, :invalid_x_nome),
         :ok <- validate_digits(opts.cpf, 11, :invalid_cpf) do
      send_event(opts, &Events.include_driver/1)
    end
  end

  @doc """
  Event 110115, adding DF-e (NF-e) to an MDF-e in transit.

  Needs `:ch_mdfe`, `:n_prot`, `:tax_id`, `:c_mun_carrega`, `:x_mun_carrega` and
  `:documents`, a non-empty list of
  `%{c_mun_descarga: ..., x_mun_descarga: ..., ch_nfe: ...}`.
  """
  @spec include_dfe(map()) :: {:ok, Result.t()} | {:error, term()}
  def include_dfe(opts) when is_map(opts),
    do: Telemetry.span(:mdfe_include_dfe, opts, &do_include_dfe/1)

  defp do_include_dfe(opts) do
    with :ok <-
           require_keys(opts, [
             :ch_mdfe,
             :n_prot,
             :c_mun_carrega,
             :x_mun_carrega,
             :documents,
             :tax_id | @common
           ]),
         :ok <- validate_event(opts),
         :ok <- validate_n_prot(opts.n_prot),
         :ok <- validate_digits(opts.c_mun_carrega, 7, :invalid_c_mun_carrega),
         :ok <- validate_text(opts.x_mun_carrega, 2..60, :invalid_x_mun_carrega),
         :ok <- validate_documents(opts.documents) do
      send_event(opts, &Events.include_dfe/1)
    end
  end

  defp validate_documents([_ | _] = documents) do
    Enum.find_value(documents, :ok, fn doc ->
      case validate_document(doc) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp validate_documents(_documents), do: {:error, :invalid_documents}

  defp validate_document(%{c_mun_descarga: c_mun, x_mun_descarga: x_mun, ch_nfe: ch_nfe}) do
    with :ok <- validate_digits(c_mun, 7, :invalid_c_mun_descarga),
         :ok <- validate_text(x_mun, 2..60, :invalid_x_mun_descarga) do
      validate_digits(ch_nfe, 44, :invalid_ch_nfe)
    end
  end

  defp validate_document(_document), do: {:error, :invalid_documents}

  defp send_event(opts, build) do
    with {:ok, url} <- url(opts, :mdfe_recepcao_evento),
         event = build.(Map.put(opts, :tp_amb, Envelope.tp_amb(opts.environment))),
         {:ok, signed} <- Signer.sign(event, opts.cert, "infEvento", "eventoMDFe"),
         {:ok, envelope} <- Envelope.wrap(:mdfe_recepcao_evento, Messages.send_event(signed)),
         {:ok, body} <- call(url, envelope, opts, :mdfe_recepcao_evento),
         {:ok, result} <- Answer.parse(body, :protocol) do
      {:ok, %{result | signed_xml: signed, xml: processed(Proc.mdfe_event_proc(signed, body))}}
    end
  end

  defp url(opts, service), do: Endpoints.url(opts.uf, opts.environment, service, 58)

  # `Result.xml` is the processed document once SEFAZ accepted it, else `nil`.
  defp processed({:ok, xml}), do: xml
  defp processed({:error, _reason}), do: nil

  # What every event needs: the environment, the key (model 58) and the author.
  defp validate_event(opts) do
    with :ok <- validate_environment(opts.environment),
         :ok <- validate_ch_mdfe(opts.ch_mdfe) do
      validate_tax_id(opts.tax_id)
    end
  end

  # The key's alphanumeric part is the CNPJ alfa; positions 21 and 22 are the
  # model, which for an MDF-e is 58.
  defp validate_ch_mdfe(<<_::binary-size(20), "58", _::binary-size(22)>> = key) do
    if String.match?(key, ~r/^\d{6}[A-Z0-9]{12}\d{26}$/),
      do: :ok,
      else: {:error, :invalid_ch_mdfe}
  end

  defp validate_ch_mdfe(_key), do: {:error, :invalid_ch_mdfe}

  defp validate_tax_id(id) when is_binary(id) and byte_size(id) == 11 do
    if String.match?(id, ~r/^\d{11}$/), do: :ok, else: {:error, :invalid_tax_id}
  end

  defp validate_tax_id(id) when is_binary(id) and byte_size(id) == 14 do
    if String.match?(id, ~r/^[A-Z0-9]{12}\d{2}$/), do: :ok, else: {:error, :invalid_tax_id}
  end

  defp validate_tax_id(_id), do: {:error, :invalid_tax_id}

  defp validate_n_prot(n_prot), do: validate_digits(n_prot, 15, :invalid_n_prot)

  defp validate_digits(value, size, error) do
    if is_binary(value) and String.match?(value, ~r/^\d+$/) and byte_size(value) == size,
      do: :ok,
      else: {:error, error}
  end

  defp validate_justification(text) when is_binary(text) do
    case String.length(text) do
      length when length < 15 -> {:error, :justification_too_short}
      length when length > 255 -> {:error, :justification_too_long}
      _length -> :ok
    end
  end

  defp validate_justification(_text), do: {:error, :justification_too_short}

  defp validate_text(text, range, error) do
    if is_binary(text) and String.length(String.trim(text)) in range,
      do: :ok,
      else: {:error, error}
  end

  defp validate_date(%Date{}), do: :ok

  defp validate_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, _date} -> :ok
      {:error, _reason} -> {:error, :invalid_dt_enc}
    end
  end

  defp validate_date(_date), do: {:error, :invalid_dt_enc}
end
