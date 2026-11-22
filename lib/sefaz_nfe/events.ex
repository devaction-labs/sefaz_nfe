defmodule SefazNfe.Events do
  @moduledoc """
  Builders for the MOC's post-authorization events and for inutilização.

  These are the only documents this library composes. AD-001 keeps NF-e XML
  with the ERP because it carries tax arithmetic; an event carries none — it is
  a key, a protocol and a justification — so composing it here does not make
  this a second fiscal engine.

  Each element is signed on its own `Id`, whose shape the MOC fixes: `ID` plus
  the event code, the access key and the two digit sequence for an event, and
  `ID` plus code, UF, year, CNPJ, model, series and number range for a voided
  range. A malformed `Id` is rejected by schema validation, so it is built here
  rather than left to the caller.
  """

  @nfe_ns "http://www.portalfiscal.inf.br/nfe"

  @cancel "110111"
  @correction "110110"
  @epec "110140"

  # Manifestação do destinatário. The description strings are compared verbatim
  # by SEFAZ, so they are data here rather than something a caller passes.
  @manifestation %{
    confirmation: {"210200", "Confirmacao da Operacao"},
    awareness: {"210210", "Ciencia da Operacao"},
    unaware: {"210220", "Desconhecimento da Operacao"},
    not_performed: {"210240", "Operacao nao Realizada"}
  }

  @correction_notice "A Carta de Correcao e disciplinada pelo paragrafo " <>
                       "1o-A do art. 7o do Convenio S/N, de 15 de dezembro de 1970 e pode ser " <>
                       "utilizada para regularizacao de erro ocorrido na emissao de documento " <>
                       "fiscal, desde que o erro nao esteja relacionado com: I - as variaveis " <>
                       "que determinam o valor do imposto tais como: base de calculo, aliquota, " <>
                       "diferenca de preco, quantidade, valor da operacao ou da prestacao; II - " <>
                       "a correcao de dados cadastrais que implique mudanca do remetente ou do " <>
                       "destinatario; III - a data de emissao ou de saida."

  @doc "Event 110111, cancelling an authorized NF-e."
  @spec cancel(map()) :: binary()
  def cancel(opts) do
    detail =
      ~s(<descEvento>Cancelamento</descEvento>) <>
        ~s(<nProt>#{opts.n_prot}</nProt>) <>
        ~s(<xJust>#{escape(opts.justification)}</xJust>)

    event(@cancel, "1.00", detail, opts)
  end

  @doc """
  Event 110110, the Carta de Correção Eletrônica.

  `xCondUso` is the fixed legal text the MOC requires verbatim; SEFAZ rejects
  the event if it differs, so it is not a caller's field.
  """
  @spec correction(map()) :: binary()
  def correction(opts) do
    detail =
      ~s(<descEvento>Carta de Correcao</descEvento>) <>
        ~s(<xCorrecao>#{escape(opts.correction)}</xCorrecao>) <>
        ~s(<xCondUso>#{@correction_notice}</xCondUso>)

    event(@correction, "1.00", detail, opts)
  end

  @doc """
  Manifestação do destinatário: events 210200, 210210, 210220 and 210240.

  This is how a recipient answers a document that DistDFe delivered, and it is
  what unlocks the full XML of a note you only received a summary of. Unlike
  cancel and CCe, these are processed by the Ambiente Nacional rather than by
  the issuing state, so `cOrgao` is 91.

  `:not_performed` requires a justification; the other three take none.
  """
  @spec manifestation(atom(), map()) :: binary()
  def manifestation(type, opts) do
    {code, description} = Map.fetch!(@manifestation, type)

    event(code, "1.00", detail(type, description, opts), Map.put(opts, :uf_code, 91))
  end

  @doc """
  Event 110140, the EPEC (Evento Prévio de Emissão em Contingência).

  `opts.epec` is what `SefazNfe.EPEC.extract/1` read from the NF-e: its values
  are copied, never derived, so the numbers SEFAZ registers are the NF-e's own.
  Like the manifestation it is processed by the Ambiente Nacional (`cOrgao` 91),
  and `opts.tax_id` is the emitter, the event's author. The element order of
  `detEvento` is the XSD's (`e110140NFe_v1.00.xsd`).
  """
  @spec epec(map()) :: binary()
  def epec(opts) do
    e = opts.epec

    detail =
      ~s(<descEvento>EPEC</descEvento>) <>
        ~s(<cOrgaoAutor>#{e.c_uf}</cOrgaoAutor><tpAutor>1</tpAutor>) <>
        ~s(<verAplic>#{escape(e.ver_aplic)}</verAplic><dhEmi>#{e.dh_emi}</dhEmi>) <>
        ~s(<tpNF>#{e.tp_nf}</tpNF><IE>#{e.ie}</IE>) <>
        ~s(<dest><UF>#{e.dest_uf}</UF>#{dest_id(e.dest_id)}#{dest_ie(e.dest_ie)}) <>
        ~s(<vNF>#{e.v_nf}</vNF><vICMS>#{e.v_icms}</vICMS><vST>#{e.v_st}</vST></dest>)

    event(@epec, "1.00", detail, Map.put(opts, :uf_code, 91))
  end

  defp dest_id({:cnpj, id}), do: ~s(<CNPJ>#{id}</CNPJ>)
  defp dest_id({:cpf, id}), do: ~s(<CPF>#{id}</CPF>)
  defp dest_id({:id_estrangeiro, id}), do: ~s(<idEstrangeiro>#{escape(id)}</idEstrangeiro>)

  defp dest_ie(nil), do: ""
  defp dest_ie(ie), do: ~s(<IE>#{ie}</IE>)

  @doc "The four manifestação types this library builds."
  @spec manifestation_types() :: [atom()]
  def manifestation_types, do: Map.keys(@manifestation)

  defp detail(:not_performed, description, opts) do
    ~s(<descEvento>#{description}</descEvento>) <>
      ~s(<xJust>#{escape(opts.justification)}</xJust>)
  end

  defp detail(_type, description, _opts), do: ~s(<descEvento>#{description}</descEvento>)

  @doc "`inutNFe` for `NFeInutilizacao4`."
  @spec void_numbers(map()) :: binary()
  def void_numbers(opts) do
    year = opts |> Map.get(:year, Date.utc_today().year) |> to_string() |> String.slice(-2, 2)
    uf_code = opts.uf_code
    tp_amb = opts.tp_amb

    id =
      "ID#{uf_code}#{year}#{opts.tax_id}#{pad(opts.model, 2)}" <>
        "#{pad(opts.serie, 3)}#{pad(opts.n_ini, 9)}#{pad(opts.n_fim, 9)}"

    ~s(<inutNFe xmlns="#{@nfe_ns}" versao="4.00">) <>
      ~s(<infInut Id="#{id}">) <>
      ~s(<tpAmb>#{tp_amb}</tpAmb><xServ>INUTILIZAR</xServ>) <>
      ~s(<cUF>#{uf_code}</cUF><ano>#{year}</ano>) <>
      ~s(<CNPJ>#{opts.tax_id}</CNPJ><mod>#{pad(opts.model, 2)}</mod>) <>
      ~s(<serie>#{opts.serie}</serie>) <>
      ~s(<nNFIni>#{opts.n_ini}</nNFIni><nNFFin>#{opts.n_fim}</nNFFin>) <>
      ~s(<xJust>#{escape(opts.justification)}</xJust>) <>
      ~s(</infInut></inutNFe>)
  end

  defp event(code, version, detail, opts) do
    sequence = Map.get(opts, :sequence, 1)
    id = "ID#{code}#{opts.ch_nfe}#{pad(sequence, 2)}"

    ~s(<evento xmlns="#{@nfe_ns}" versao="1.00">) <>
      ~s(<infEvento Id="#{id}">) <>
      ~s(<cOrgao>#{opts.uf_code}</cOrgao><tpAmb>#{opts.tp_amb}</tpAmb>) <>
      ~s(#{author(opts.tax_id)}<chNFe>#{opts.ch_nfe}</chNFe>) <>
      ~s(<dhEvento>#{timestamp(opts)}</dhEvento>) <>
      ~s(<tpEvento>#{code}</tpEvento><nSeqEvento>#{sequence}</nSeqEvento>) <>
      ~s(<verEvento>#{version}</verEvento>) <>
      ~s(<detEvento versao="#{version}">#{detail}</detEvento>) <>
      ~s(</infEvento></evento>)
  end

  # The XSD's author is a choice of CNPJ or CPF; a natural-person emitter (a
  # producer rural, say) has 11 digits.
  defp author(id) when byte_size(id) == 11, do: "<CPF>#{id}</CPF>"
  defp author(id), do: "<CNPJ>#{id}</CNPJ>"

  # The MOC wants a local time with an explicit offset, never UTC with a Z, and
  # second precision: a microsecond field fails the schema as cStat 225. Both
  # DateTime.to_iso8601/1 and NaiveDateTime.to_iso8601/1 emit one when the
  # struct carries it, so it is trimmed here rather than left to the caller.
  defp timestamp(opts) do
    opts
    |> Map.get_lazy(:timestamp, fn ->
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end)
    |> String.replace("Z", "+00:00")
    |> trim_precision()
  end

  defp trim_precision(<<stamp::binary-size(19), rest::binary>>) do
    stamp <> String.replace(rest, ~r/^\.\d+/, "")
  end

  defp trim_precision(stamp), do: stamp

  defp pad(value, size), do: value |> to_string() |> String.pad_leading(size, "0")

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
