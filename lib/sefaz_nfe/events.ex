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
      ~s(<CNPJ>#{opts.tax_id}</CNPJ><chNFe>#{opts.ch_nfe}</chNFe>) <>
      ~s(<dhEvento>#{timestamp(opts)}</dhEvento>) <>
      ~s(<tpEvento>#{code}</tpEvento><nSeqEvento>#{sequence}</nSeqEvento>) <>
      ~s(<verEvento>#{version}</verEvento>) <>
      ~s(<detEvento versao="#{version}">#{detail}</detEvento>) <>
      ~s(</infEvento></evento>)
  end

  # The MOC wants a local time with an explicit offset, never UTC with a Z.
  defp timestamp(opts) do
    Map.get_lazy(opts, :timestamp, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)
    |> String.replace("Z", "+00:00")
  end

  defp pad(value, size), do: value |> to_string() |> String.pad_leading(size, "0")

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
