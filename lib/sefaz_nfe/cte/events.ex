defmodule SefazNfe.CTe.Events do
  @moduledoc """
  Builders for the CT-e (model 57 and 67) events, layout 4.00.

  Like `SefazNfe.Events`, these carry no tax arithmetic: a key, a protocol and
  a few facts. The shape differs from the NF-e's in four ways, all from
  `eventoCTe_v4.00.xsd` (and confirmed against NFePHP `sped-cte`):

    * the root is `eventoCTe` (`versao` 4.00) in the CT-e namespace, sent alone:
      there is no `envEvento` and no `idLote`;
    * the key is `chCTe`, and `detEvento` carries `versaoEvento`, not `versao`;
    * `detEvento` holds one element per event (`evCancCTe`, `evCCeCTe`,
      `evCECTe`, `evCancCECTe`, `evIECTe`, `evCancIECTe`), where an NF-e event
      puts its fields in `detEvento` directly;
    * `nSeqEvento` and the last part of `Id` have three digits.

  | Event | Code | Element |
  |-------|------|---------|
  | cancel | 110111 | `evCancCTe` |
  | CC-e | 110110 | `evCCeCTe` |
  | delivery proof | 110180 | `evCECTe` |
  | cancel of the delivery proof | 110181 | `evCancCECTe` |
  | delivery failure | 110190 | `evIECTe` |
  | cancel of the delivery failure | 110191 | `evCancIECTe` |

  ## The delivery hash

  `hashEntrega` and `hashTentativaEntrega` are, per the MOC and the XSD,
  "Hash (SHA1) no formato Base64 resultante da concatenacao: Chave de acesso
  do CT-e + Base64 da imagem capturada". `delivery_hash/2` is exactly that:
  `Base.encode64(sha1(ch_cte <> Base.encode64(image)))`, where the
  concatenation is of the two ASCII texts, not of the key and the raw image
  bytes. The result is 28 characters (the XSD's 20-byte `base64Binary`). The MOC
  adds that SEFAZ has no control over the field: it is the author's own index to
  the proof it keeps. NFePHP only forwards a hash the caller computed.
  """

  @cte_ns "http://www.portalfiscal.inf.br/cte"
  @version "4.00"

  @cancel "110111"
  @correction "110110"
  @delivery_proof "110180"
  @cancel_delivery_proof "110181"
  @delivery_failure "110190"
  @cancel_delivery_failure "110191"

  # The unaccented variant of `xCondUso`, which the XSD lists next to the
  # accented one; SEFAZ compares it verbatim.
  @correction_notice "A Carta de Correcao e disciplinada pelo Art. 58-B do CONVENIO/SINIEF " <>
                       "06/89: Fica permitida a utilizacao de carta de correcao, para " <>
                       "regularizacao de erro ocorrido na emissao de documentos fiscais " <>
                       "relativos a prestacao de servico de transporte, desde que o erro nao " <>
                       "esteja relacionado com: I - as variaveis que determinam o valor do " <>
                       "imposto tais como: base de calculo, aliquota, diferenca de preco, " <>
                       "quantidade, valor da prestacao;II - a correcao de dados cadastrais " <>
                       "que implique mudanca do emitente, tomador, remetente ou do " <>
                       "destinatario;III - a data de emissao ou de saida."

  @doc "Event 110111, cancelling an authorized CT-e."
  @spec cancel(map()) :: binary()
  def cancel(opts) do
    detail =
      "<evCancCTe><descEvento>Cancelamento</descEvento>" <>
        "<nProt>#{opts.n_prot}</nProt><xJust>#{escape(opts.justification)}</xJust></evCancCTe>"

    event(@cancel, detail, opts)
  end

  @doc """
  Event 110110, the structured Carta de Correcao.

  `opts.corrections` is a list of maps with `:grupo_alterado`, `:campo_alterado`
  and `:valor_alterado`, and optionally `:nro_item_alterado` (the 1-based index
  when the corrected field is in a list). `xCondUso` is the fixed legal text.
  """
  @spec correction(map()) :: binary()
  def correction(opts) do
    corrections = Enum.map_join(opts.corrections, &correction_item/1)

    detail =
      "<evCCeCTe><descEvento>Carta de Correcao</descEvento>" <>
        corrections <> "<xCondUso>#{@correction_notice}</xCondUso></evCCeCTe>"

    event(@correction, detail, opts)
  end

  defp correction_item(item) do
    "<infCorrecao><grupoAlterado>#{escape(item.grupo_alterado)}</grupoAlterado>" <>
      "<campoAlterado>#{escape(item.campo_alterado)}</campoAlterado>" <>
      "<valorAlterado>#{escape(item.valor_alterado)}</valorAlterado>" <>
      item_number(Map.get(item, :nro_item_alterado)) <> "</infCorrecao>"
  end

  defp item_number(nil), do: ""
  defp item_number(n), do: "<nroItemAlterado>#{n}</nroItemAlterado>"

  @doc """
  Event 110180, the comprovante de entrega.

  `opts`: `:n_prot` (of the CT-e), `:dh_entrega`, `:n_doc`, `:x_nome`, `:image`
  (the proof's bytes, hashed here, see the moduledoc) and optionally
  `:latitude`, `:longitude`, `:ch_nfes` (the NF-e keys delivered, for a normal
  service) and `:dh_hash` (when the hash was generated; `dhEntrega` by default).
  """
  @spec delivery_proof(map()) :: binary()
  def delivery_proof(opts) do
    dh_entrega = time(opts.dh_entrega)

    detail =
      "<evCECTe><descEvento>Comprovante de Entrega do CT-e</descEvento>" <>
        "<nProt>#{opts.n_prot}</nProt><dhEntrega>#{dh_entrega}</dhEntrega>" <>
        "<nDoc>#{escape(opts.n_doc)}</nDoc><xNome>#{escape(opts.x_nome)}</xNome>" <>
        coordinates(opts) <>
        "<hashEntrega>#{delivery_hash(opts.ch_cte, opts.image)}</hashEntrega>" <>
        "<dhHashEntrega>#{hash_time(opts, dh_entrega)}</dhHashEntrega>" <>
        deliveries(opts) <> "</evCECTe>"

    event(@delivery_proof, detail, opts)
  end

  @doc "Event 110181, cancelling the delivery proof whose protocol is `:n_prot_ce`."
  @spec cancel_delivery_proof(map()) :: binary()
  def cancel_delivery_proof(opts) do
    detail =
      "<evCancCECTe><descEvento>Cancelamento do Comprovante de Entrega do CT-e</descEvento>" <>
        "<nProt>#{opts.n_prot}</nProt><nProtCE>#{opts.n_prot_ce}</nProtCE></evCancCECTe>"

    event(@cancel_delivery_proof, detail, opts)
  end

  @doc """
  Event 110190, the insucesso na entrega.

  `opts`: `:n_prot`, `:dh_tentativa_entrega`, `:tp_motivo` (1 recebedor nao
  encontrado, 2 recusa do recebedor, 3 endereco inexistente, 4 outros) and
  optionally `:n_tentativa` (three digits), `:x_just_motivo` (required with
  motivo 4), `:latitude`, `:longitude`, `:image` (hashed here; without it the
  hash group is left out, as the XSD allows), `:dh_hash` and `:ch_nfes`.
  """
  @spec delivery_failure(map()) :: binary()
  def delivery_failure(opts) do
    dh_tentativa = time(opts.dh_tentativa_entrega)

    detail =
      "<evIECTe><descEvento>Insucesso na Entrega do CT-e</descEvento>" <>
        "<nProt>#{opts.n_prot}</nProt>" <>
        "<dhTentativaEntrega>#{dh_tentativa}</dhTentativaEntrega>" <>
        optional("nTentativa", pad_optional(Map.get(opts, :n_tentativa), 3)) <>
        "<tpMotivo>#{opts.tp_motivo}</tpMotivo>" <>
        optional("xJustMotivo", escape_optional(Map.get(opts, :x_just_motivo))) <>
        coordinates(opts) <>
        failure_hash(opts, dh_tentativa) <> deliveries(opts) <> "</evIECTe>"

    event(@delivery_failure, detail, opts)
  end

  defp failure_hash(%{image: image} = opts, dh_tentativa) when is_binary(image) do
    "<hashTentativaEntrega>#{delivery_hash(opts.ch_cte, image)}</hashTentativaEntrega>" <>
      "<dhHashTentativaEntrega>#{hash_time(opts, dh_tentativa)}</dhHashTentativaEntrega>"
  end

  defp failure_hash(_opts, _dh_tentativa), do: ""

  @doc "Event 110191, cancelling the delivery failure whose protocol is `:n_prot_ie`."
  @spec cancel_delivery_failure(map()) :: binary()
  def cancel_delivery_failure(opts) do
    detail =
      "<evCancIECTe><descEvento>Cancelamento do Insucesso de Entrega do CT-e</descEvento>" <>
        "<nProt>#{opts.n_prot}</nProt><nProtIE>#{opts.n_prot_ie}</nProtIE></evCancIECTe>"

    event(@cancel_delivery_failure, detail, opts)
  end

  @doc """
  The delivery hash: `Base.encode64(sha1(ch_cte <> Base.encode64(image)))`. See
  the moduledoc.
  """
  @spec delivery_hash(String.t(), binary()) :: String.t()
  def delivery_hash(ch_cte, image) when is_binary(ch_cte) and is_binary(image) do
    :sha |> :crypto.hash(ch_cte <> Base.encode64(image)) |> Base.encode64()
  end

  defp coordinates(opts) do
    optional("latitude", coordinate(Map.get(opts, :latitude))) <>
      optional("longitude", coordinate(Map.get(opts, :longitude)))
  end

  # The XSD wants exactly six decimals ("-12.345678"); a float is formatted to
  # them, and a string is the caller's and goes as it is.
  defp coordinate(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 6)
  defp coordinate(value), do: value

  defp deliveries(opts) do
    opts
    |> Map.get(:ch_nfes, [])
    |> Enum.map_join(&"<infEntrega><chNFe>#{&1}</chNFe></infEntrega>")
  end

  defp hash_time(opts, default), do: opts |> Map.get(:dh_hash, default) |> time()

  defp optional(_tag, nil), do: ""
  defp optional(tag, value), do: "<#{tag}>#{value}</#{tag}>"

  defp pad_optional(nil, _size), do: nil
  defp pad_optional(value, size), do: pad(value, size)

  defp escape_optional(nil), do: nil
  defp escape_optional(text), do: escape(text)

  defp event(code, detail, opts) do
    sequence = Map.get(opts, :sequence, 1)
    seq = pad(sequence, 3)

    ~s(<eventoCTe xmlns="#{@cte_ns}" versao="#{@version}">) <>
      ~s(<infEvento Id="ID#{code}#{opts.ch_cte}#{seq}">) <>
      ~s(<cOrgao>#{opts.uf_code}</cOrgao><tpAmb>#{opts.tp_amb}</tpAmb>) <>
      ~s(#{author(opts.tax_id)}<chCTe>#{opts.ch_cte}</chCTe>) <>
      ~s(<dhEvento>#{time(Map.get_lazy(opts, :timestamp, &DateTime.utc_now/0))}</dhEvento>) <>
      ~s(<tpEvento>#{code}</tpEvento><nSeqEvento>#{seq}</nSeqEvento>) <>
      ~s(<detEvento versaoEvento="#{@version}">#{detail}</detEvento>) <>
      ~s(</infEvento></eventoCTe>)
  end

  defp author(id) when byte_size(id) == 11, do: "<CPF>#{id}</CPF>"
  defp author(id), do: "<CNPJ>#{id}</CNPJ>"

  # `TDateTimeUTC`: local time with an explicit offset, second precision, no Z.
  # A DateTime is formatted here; a string is trimmed to the same shape.
  defp time(%DateTime{} = datetime) do
    datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601() |> time()
  end

  defp time(text) when is_binary(text) do
    text |> String.replace("Z", "+00:00") |> trim_precision()
  end

  defp trim_precision(<<stamp::binary-size(19), rest::binary>>) do
    stamp <> String.replace(rest, ~r/^\.\d+/, "")
  end

  defp trim_precision(stamp), do: stamp

  defp pad(value, size), do: value |> to_string() |> String.pad_leading(size, "0")

  defp escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
