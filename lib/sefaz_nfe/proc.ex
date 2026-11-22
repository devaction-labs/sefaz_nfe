defmodule SefazNfe.Proc do
  @moduledoc """
  Assembles the processed documents that are archived and delivered: the signed
  document plus SEFAZ's answer (NFePHP's `Complements`).

  | Function | Result | Parts |
  |----------|--------|-------|
  | `nfe_proc/2` | `nfeProc` | `NFe` + `protNFe` |
  | `event_proc/2` | `procEventoNFe` | `evento` + `retEvento` |
  | `void_proc/2` | `procInutNFe` | `inutNFe` + `retInutNFe` |
  | `cancel_register/2` | the same `nfeProc` | + the cancellation's `retEvento` |

  ## Bytes are spliced, never re-serialised (AD-011)

  The signature covers the document exactly as it was sent, and the protocol is
  SEFAZ's own. Both are copied byte for byte out of what the caller passed (the
  signed document, the SOAP body of the answer) and wrapped; nothing is parsed
  and written back. The only thing removed is the XML declaration of the inner
  document, which a wrapper cannot carry twice. The wrapper declares the NF-e
  namespace, which is what lets the answer's elements, that inherit it from
  the SOAP body they were cut from, stay in it.

  The answer may be the whole SOAP envelope, the `retEnviNFe` / `retEnvEvento` /
  `retInutNFe` or the element itself. Its elements are found unprefixed, the
  way SEFAZ sends them.

  ## What is checked

  Like NFePHP, an answer is only joined to the document it is about, and only
  when SEFAZ accepted it:

    * `nfe_proc/2`: the `protNFe` whose `chNFe` is the document's key (`Id`
      without `NFe`) and, when both carry one, whose `digVal` is the document's
      `DigestValue`; `cStat` 100, 150, 120, 110, 205, 301, 302 or 303 (the
      authorized and the denied ones: a denial is archived too).
    * `event_proc/2`: the `retEvento` of the same `chNFe` and `tpEvento`; `cStat`
      135 or 136, and 155 for a cancellation (110111).
    * `void_proc/2`: `cStat` 102 and the same `versao`, `tpAmb`, `cUF`, `ano`,
      `CNPJ`/`CPF`, `mod`, `serie`, `nNFIni` and `nNFFin` as the request.
    * `cancel_register/2`: `cStat` 135, 136 or 155, `tpEvento` 110111 or 110112
      (cancelamento por substituição) and the `chNFe` of the `nfeProc`.

  Each returns `{:ok, xml}` or `{:error, reason}`:

    * `:no_protocol`, `:no_event_return`, `:no_void_return` - the answer has no
      such element (a receipt, a rejection of the batch);
    * `:key_mismatch`, `:digest_mismatch`, `{:mismatch, field}` - it is about
      another document;
    * `{:not_accepted, c_stat}` - SEFAZ did not accept it;
    * `{:not_a_cancellation, tp_evento}` - `cancel_register/2` of another event;
    * `{:xml, reason}` - a part is not XML (`SefazNfe.XML`).

  `SefazNfe.Result.xml` is what these return, for the authorization, events and
  voiding of the facade.
  """

  alias SefazNfe.XML

  @nfe_ns "http://www.portalfiscal.inf.br/nfe"
  @declaration ~r/^\s*<\?xml[^>]*\?>/

  @authorized_c_stats [100, 150, 120, 110, 205, 301, 302, 303]
  @event_c_stats [135, 136]
  @cancel_c_stats [135, 136, 155]
  @cancel_events ["110111", "110112"]

  @type reason :: term()

  # nfeProc ------------------------------------------------------------------

  @doc """
  `nfeProc`: the signed `NFe` and its `protNFe`, from the answer of the
  authorization or of a protocol query.
  """
  @spec nfe_proc(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def nfe_proc(signed_nfe_xml, response)
      when is_binary(signed_nfe_xml) and is_binary(response) do
    with {:ok, doc} <- XML.parse(signed_nfe_xml),
         {:ok, key, digest} <- document_facts(doc),
         {:ok, protocol} <- protocol_for(response, key, digest),
         :ok <- accepted(protocol, @authorized_c_stats) do
      {:ok, wrap("nfeProc", version(doc), [strip(signed_nfe_xml), protocol.raw])}
    end
  end

  defp document_facts(doc) do
    case XML.attribute(doc, "infNFe", "Id") do
      "NFe" <> key -> {:ok, key, XML.text(doc, "DigestValue")}
      _no_id -> {:error, :no_inf_nfe}
    end
  end

  defp version(doc), do: XML.attribute(doc, "infNFe", "versao") || "4.00"

  defp protocol_for(response, key, digest) do
    case elements(response, "protNFe") do
      [] ->
        {:error, :no_protocol}

      protocols ->
        protocols
        |> Enum.map(&facts/1)
        |> Enum.find_value({:error, :key_mismatch}, &protocol_match(&1, key, digest))
    end
  end

  defp protocol_match(%{ch_nfe: key} = protocol, key, digest) do
    case protocol.dig_val do
      nil -> {:ok, protocol}
      ^digest -> {:ok, protocol}
      _other when is_nil(digest) -> {:ok, protocol}
      _other -> {:error, :digest_mismatch}
    end
  end

  defp protocol_match(_protocol, _key, _digest), do: nil

  # procEventoNFe ------------------------------------------------------------

  @doc """
  `procEventoNFe`: the signed `evento` and the `retEvento` SEFAZ answered it
  with, for a cancellation, a CCe, an EPEC or a manifestação.

  `signed_event_xml` is the signed `evento` (or an `envEvento` holding it).
  """
  @spec event_proc(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def event_proc(signed_event_xml, response)
      when is_binary(signed_event_xml) and is_binary(response) do
    with {:ok, event} <- first_element(signed_event_xml, "evento", :no_event),
         {:ok, doc} <- XML.parse(event),
         {:ok, returned} <- event_return(response, facts(event)),
         :ok <- accepted(returned, event_c_stats(returned.tp_evento)) do
      {:ok,
       wrap("procEventoNFe", XML.attribute(doc, "evento", "versao") || "1.00", [
         event,
         returned.raw
       ])}
    end
  end

  defp event_c_stats("110111"), do: @cancel_c_stats
  defp event_c_stats(_tp_evento), do: @event_c_stats

  defp event_return(response, %{ch_nfe: key, tp_evento: tp_evento}) do
    case elements(response, "retEvento") do
      [] ->
        {:error, :no_event_return}

      returns ->
        returns
        |> Enum.map(&facts/1)
        |> Enum.find({:error, :key_mismatch}, &(&1.ch_nfe == key and &1.tp_evento == tp_evento))
        |> then(fn
          {:error, _reason} = error -> error
          found -> {:ok, found}
        end)
    end
  end

  # procInutNFe --------------------------------------------------------------

  @void_fields [
    tp_amb: "tpAmb",
    c_uf: "cUF",
    ano: "ano",
    mod: "mod",
    serie: "serie",
    n_nf_ini: "nNFIni",
    n_nf_fin: "nNFFin"
  ]

  @doc """
  `procInutNFe`: the signed `inutNFe` and SEFAZ's `retInutNFe`.
  """
  @spec void_proc(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def void_proc(signed_inut_xml, response)
      when is_binary(signed_inut_xml) and is_binary(response) do
    with {:ok, inut} <- first_element(signed_inut_xml, "inutNFe", :no_inut),
         {:ok, request} <- XML.parse(inut),
         {:ok, returned} <- first_element(response, "retInutNFe", :no_void_return),
         {:ok, answer} <- XML.parse(returned),
         :ok <- accepted(%{c_stat: XML.integer(answer, "cStat")}, [102]),
         :ok <- same_void(request, answer) do
      version = XML.attribute(request, "inutNFe", "versao") || "4.00"
      {:ok, wrap("procInutNFe", version, [inut, returned])}
    end
  end

  defp same_void(request, answer) do
    checks =
      [
        versao:
          {XML.attribute(request, "inutNFe", "versao"),
           XML.attribute(answer, "retInutNFe", "versao")}
      ] ++
        Enum.map(@void_fields, fn {field, tag} ->
          {field, {XML.text(request, tag), XML.text(answer, tag) || fallback(field, request)}}
        end) ++
        [tax_id: {tax_id(request), tax_id(answer)}]

    case Enum.find(checks, fn {_field, {sent, got}} -> sent != got end) do
      nil -> :ok
      {field, _values} -> {:error, {:mismatch, field}}
    end
  end

  # NFePHP reads the UF from the request when the answer leaves it out.
  defp fallback(:c_uf, request), do: XML.text(request, "cUF")
  defp fallback(_field, _request), do: nil

  defp tax_id(doc), do: XML.text(doc, "CNPJ") || XML.text(doc, "CPF")

  # cancel_register ----------------------------------------------------------

  @doc """
  Marks an authorized `nfeProc` as cancelled by appending the cancellation's
  `retEvento` after its `protNFe` (NFePHP's `cancelRegister`).

  `event_xml` is the `procEventoNFe` from `event_proc/2` or SEFAZ's answer
  itself; the first `retEvento` that is an accepted cancellation (110111 or
  110112) of the `nfeProc`'s key is the one appended. It is spliced as
  received. Registering the same `retEvento` again returns the `nfeProc`
  unchanged.

  Unlike NFePHP, which returns the `nfeProc` untouched for anything else, an
  answer that does not qualify is an error that says why: `:no_protocol` (the
  `nfeProc` carries no `protNFe`), `:no_event_return`, `:key_mismatch`,
  `{:not_a_cancellation, tp_evento}` or `{:not_accepted, c_stat}`.
  """
  @spec cancel_register(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def cancel_register(nfe_proc_xml, event_xml)
      when is_binary(nfe_proc_xml) and is_binary(event_xml) do
    with {:ok, protocol} <- first_element(nfe_proc_xml, "protNFe", :no_protocol),
         :ok <- closes_with_nfe_proc(nfe_proc_xml),
         {:ok, returned} <- cancellation(event_xml, facts(protocol).ch_nfe) do
      {:ok, append(nfe_proc_xml, returned.raw)}
    end
  end

  defp closes_with_nfe_proc(xml),
    do: if(Regex.match?(~r{</nfeProc>\s*\z}, xml), do: :ok, else: {:error, :not_an_nfe_proc})

  defp cancellation(event_xml, key) do
    case elements(event_xml, "retEvento") do
      [] ->
        {:error, :no_event_return}

      returns ->
        outcomes = Enum.map(returns, &cancellation_outcome(facts(&1), key))
        Enum.find(outcomes, hd(outcomes), &match?({:ok, _}, &1))
    end
  end

  defp cancellation_outcome(%{ch_nfe: key} = returned, key) do
    cond do
      returned.tp_evento not in @cancel_events ->
        {:error, {:not_a_cancellation, returned.tp_evento}}

      returned.c_stat not in @cancel_c_stats ->
        {:error, {:not_accepted, returned.c_stat}}

      true ->
        {:ok, returned}
    end
  end

  defp cancellation_outcome(_returned, _key), do: {:error, :key_mismatch}

  defp append(proc, returned) do
    if String.contains?(proc, returned) do
      proc
    else
      Regex.replace(~r{</nfeProc>\s*\z}, proc, fn _match -> returned <> "</nfeProc>" end)
    end
  end

  # MDF-e --------------------------------------------------------------------

  @doc "`mdfeProc` (MDF-e 58). See `SefazNfe.MDFe.Proc.mdfe_proc/2`."
  @spec mdfe_proc(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  defdelegate mdfe_proc(signed_mdfe_xml, response), to: SefazNfe.MDFe.Proc

  @doc "`procEventoMDFe`. See `SefazNfe.MDFe.Proc.mdfe_event_proc/2`."
  @spec mdfe_event_proc(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  defdelegate mdfe_event_proc(signed_event_xml, response), to: SefazNfe.MDFe.Proc

  @doc "Marks an `mdfeProc` cancelled. See `SefazNfe.MDFe.Proc.mdfe_cancel_register/2`."
  @spec mdfe_cancel_register(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  defdelegate mdfe_cancel_register(mdfe_proc_xml, event_xml), to: SefazNfe.MDFe.Proc

  @doc "Marks an `mdfeProc` closed (NFePHP `closeRegister`). See `SefazNfe.MDFe.Proc.mdfe_close_register/2`."
  @spec mdfe_close_register(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  defdelegate mdfe_close_register(mdfe_proc_xml, event_xml), to: SefazNfe.MDFe.Proc

  # Pieces -------------------------------------------------------------------

  # The first element named `name` of `xml`, as the bytes it was written with.
  defp first_element(xml, name, missing) do
    case elements(xml, name) do
      [element | _more] -> {:ok, element}
      [] -> {:error, missing}
    end
  end

  # Every non-nested `<name ...>...</name>` of `xml`, verbatim. `name` is
  # followed by whitespace, `>` or `/`, so `retEvento` never matches
  # `retEnvEvento`.
  defp elements(xml, name) do
    ~r{<#{name}(?=[\s>])(?:[^>]*/>|.*?</#{name}>)}s
    |> Regex.scan(xml)
    |> Enum.map(fn [element] -> element end)
  end

  # What an answer element says about itself. `raw` is the element's bytes.
  defp facts(raw) do
    case XML.parse(raw) do
      {:ok, doc} ->
        %{
          raw: raw,
          ch_nfe: XML.text(doc, "chNFe"),
          tp_evento: XML.text(doc, "tpEvento"),
          dig_val: XML.text(doc, "digVal"),
          c_stat: XML.integer(doc, "cStat")
        }

      {:error, _reason} ->
        %{raw: raw, ch_nfe: nil, tp_evento: nil, dig_val: nil, c_stat: nil}
    end
  end

  defp accepted(%{c_stat: c_stat}, accepted) do
    if c_stat in accepted, do: :ok, else: {:error, {:not_accepted, c_stat}}
  end

  defp strip(xml), do: Regex.replace(@declaration, xml, "")

  defp wrap(name, version, parts) do
    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<#{name} xmlns="#{@nfe_ns}" versao="#{version}">),
      parts,
      "</#{name}>"
    ])
  end
end
