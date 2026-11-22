defmodule SefazNfe.MDFe.Events do
  @moduledoc """
  Builders for the MDF-e (modelo 58) events, layout 3.00.

  Like `SefazNfe.Events` these compose no fiscal arithmetic: an event is a key,
  a protocol and a few facts, so building it here keeps the library a transport
  without making it a second fiscal engine. Each is signed on `infEvento` by the
  caller of these builders and sent as plain XML (not gzip) in `mdfeDadosMsg`.

  | Function | `tpEvento` | `detEvento` |
  |----------|-----------|-------------|
  | `cancel/1` | 110111 | `evCancMDFe` |
  | `close/1` | 110112 | `evEncMDFe` |
  | `include_driver/1` | 110114 | `evIncCondutorMDFe` |
  | `include_dfe/1` | 110115 | `evIncDFeMDFe` |

  ## Shape (`eventoMDFeTiposBasico_v3.00.xsd`)

  The root is `eventoMDFe versao="3.00"` and `detEvento` carries
  `versaoEvento="3.00"` (not `versao`, unlike the NF-e). `Id` is `ID` plus the
  event code, the access key and the sequence padded to two digits.
  `nSeqEvento` is the number as is (1 to 3 digits). `cOrgao` is the emitter's UF
  code, the first two digits of the key; SVRS receives every UF's events.

  Options common to all: `:ch_mdfe`, `:tax_id` (the author: CNPJ or CPF of the
  emitter), `:tp_amb` (1 or 2) and optionally `:sequence` (1) and `:timestamp`.
  """

  @mdfe_ns "http://www.portalfiscal.inf.br/mdfe"
  @version "3.00"

  @doc "Event 110111, cancelling an authorized MDF-e."
  @spec cancel(map()) :: binary()
  def cancel(opts) do
    detail =
      "<evCancMDFe><descEvento>Cancelamento</descEvento>" <>
        "<nProt>#{opts.n_prot}</nProt><xJust>#{escape(opts.justification)}</xJust></evCancMDFe>"

    event("110111", detail, opts)
  end

  @doc """
  Event 110112, the encerramento.

  `:dt_enc` is a `Date` or a `YYYY-MM-DD` string; `:c_uf` and `:c_mun` are the
  IBGE codes of where the MDF-e ended. `:ind_enc_por_terceiro` (`true`, or
  `1`) adds `indEncPorTerceiro` 1, the only value the XSD allows.
  """
  @spec close(map()) :: binary()
  def close(opts) do
    detail =
      "<evEncMDFe><descEvento>Encerramento</descEvento><nProt>#{opts.n_prot}</nProt>" <>
        "<dtEnc>#{date(opts.dt_enc)}</dtEnc><cUF>#{opts.c_uf}</cUF><cMun>#{opts.c_mun}</cMun>" <>
        third_party(Map.get(opts, :ind_enc_por_terceiro)) <> "</evEncMDFe>"

    event("110112", detail, opts)
  end

  @doc """
  Event 110114, adding a driver (`:x_nome`, `:cpf`).

  The XSD (`evIncCondutorMDFe_v3.00.xsd`) has no `nProt`, so none is sent even
  when the caller has it.
  """
  @spec include_driver(map()) :: binary()
  def include_driver(opts) do
    detail =
      "<evIncCondutorMDFe><descEvento>Inclusao Condutor</descEvento><condutor>" <>
        "<xNome>#{escape(opts.x_nome)}</xNome><CPF>#{opts.cpf}</CPF></condutor></evIncCondutorMDFe>"

    event("110114", detail, opts)
  end

  @doc """
  Event 110115, adding DF-e to a MDF-e in transit.

  `:documents` is a non-empty list of `%{c_mun_descarga, x_mun_descarga, ch_nfe}`.
  """
  @spec include_dfe(map()) :: binary()
  def include_dfe(opts) do
    detail =
      "<evIncDFeMDFe><descEvento>Inclusao DF-e</descEvento><nProt>#{opts.n_prot}</nProt>" <>
        "<cMunCarrega>#{opts.c_mun_carrega}</cMunCarrega>" <>
        "<xMunCarrega>#{escape(opts.x_mun_carrega)}</xMunCarrega>" <>
        Enum.map_join(opts.documents, &document/1) <> "</evIncDFeMDFe>"

    event("110115", detail, opts)
  end

  defp document(doc) do
    "<infDoc><cMunDescarga>#{doc.c_mun_descarga}</cMunDescarga>" <>
      "<xMunDescarga>#{escape(doc.x_mun_descarga)}</xMunDescarga>" <>
      "<chNFe>#{doc.ch_nfe}</chNFe></infDoc>"
  end

  defp third_party(flag) when flag in [true, 1, "1"],
    do: "<indEncPorTerceiro>1</indEncPorTerceiro>"

  defp third_party(_flag), do: ""

  defp date(%Date{} = date), do: Date.to_iso8601(date)
  defp date(date) when is_binary(date), do: date

  defp event(code, detail, opts) do
    sequence = Map.get(opts, :sequence, 1)
    key = opts.ch_mdfe

    ~s(<eventoMDFe xmlns="#{@mdfe_ns}" versao="#{@version}">) <>
      ~s(<infEvento Id="ID#{code}#{key}#{pad(sequence, 2)}">) <>
      ~s(<cOrgao>#{binary_part(key, 0, 2)}</cOrgao><tpAmb>#{opts.tp_amb}</tpAmb>) <>
      ~s(#{author(opts.tax_id)}<chMDFe>#{key}</chMDFe>) <>
      ~s(<dhEvento>#{timestamp(opts)}</dhEvento>) <>
      ~s(<tpEvento>#{code}</tpEvento><nSeqEvento>#{sequence}</nSeqEvento>) <>
      ~s(<detEvento versaoEvento="#{@version}">#{detail}</detEvento>) <>
      ~s(</infEvento></eventoMDFe>)
  end

  defp author(id) when byte_size(id) == 11, do: "<CPF>#{id}</CPF>"
  defp author(id), do: "<CNPJ>#{id}</CNPJ>"

  # Local time with an explicit offset and whole seconds, the XSD's
  # `TDateTimeUTC`: a `Z` or a fraction fails the schema (cStat 225).
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
