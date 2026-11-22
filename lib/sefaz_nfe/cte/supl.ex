defmodule SefazNfe.CTe.Supl do
  @moduledoc """
  `infCTeSupl` with the QR code (`qrCodCTe`), mandatory in CT-e 4.00 (MOC rule
  G212/rejeicao 850).

  For a normal emission (and for SVC, which the MOC treats like it) the text is
  the on-line, signature-less form:

      {qr_url}?chCTe={chave}&tpAmb={tpAmb}

  `qr_url` is the portal of the authorizer serving the emitting UF
  (`SefazNfe.Endpoints.cte_qr_code_url/2`). Rejeicao 854 forbids a `sign`
  parameter outside contingency, so none is added.

  The contingency forms that do carry `&sign=` (`tpEmis` 4, EPEC, and 5, FS-DA:
  a base64 RSA-SHA1 of the key, signed with the certificate) are not
  generated: `SefazNfe.CTe` does not route those emissions (AD-005) and `put/3`
  answers `{:error, {:unsupported, {:tp_emis, n}}}` for them rather than a QR
  code SEFAZ would reject as 855.

  ## Placement

  `infCTeSupl` follows `infCte`/`infCTeNorm` and precedes `Signature`; it is
  not covered by the signature, whose only `Reference` is `infCte`'s `Id`. It is
  spliced into the already signed bytes by byte offset, the way
  `SefazNfe.NFCe.put_supl/4` does. A document that already carries one is
  returned as it is. The text is XML-escaped, which is the `&` of the query.
  """

  alias SefazNfe.Endpoints
  alias SefazNfe.XML

  @supl ~r/<(?:[\w.-]+:)?infCTeSupl[\s>]/
  @signature ~r/<(?:[\w.-]+:)?Signature[\s>]/
  @root_close ~r{</(?:[\w.-]+:)?CTe(?:OS)?>\s*\z}

  @doc """
  Makes sure the CT-e (or CT-e OS) `xml` carries an `infCTeSupl`.

  `uf` is the emitting UF, which selects the portal; `environment` selects
  between the production and homologation tables. The key and `tpAmb` come from
  the document.
  """
  @spec put(String.t(), String.t() | atom(), Endpoints.environment()) ::
          {:ok, String.t()} | {:error, term()}
  def put(xml, uf, environment) when is_binary(xml) do
    if Regex.match?(@supl, xml) do
      {:ok, xml}
    else
      with {:ok, doc} <- XML.parse(xml),
           :ok <- on_line(XML.text(doc, "tpEmis")),
           {:ok, key} <- access_key(XML.attribute(doc, "infCte", "Id")),
           {:ok, tp_amb} <- tp_amb(XML.text(doc, "tpAmb")),
           {:ok, qr_url} <- Endpoints.cte_qr_code_url(uf, environment) do
        splice(xml, qr_code(qr_url, key, tp_amb))
      end
    end
  end

  @doc "The on-line QR code text: `{qr_url}?chCTe={key}&tpAmb={tp_amb}`."
  @spec qr_code(String.t(), String.t(), String.t()) :: String.t()
  def qr_code(qr_url, key, tp_amb), do: "#{qr_url}?chCTe=#{key}&tpAmb=#{tp_amb}"

  defp on_line(tp_emis) when tp_emis in [nil, "1", "7", "8"], do: :ok
  defp on_line(tp_emis), do: {:error, {:unsupported, {:tp_emis, tp_emis}}}

  defp access_key("CTe" <> key) when byte_size(key) == 44, do: {:ok, key}
  defp access_key(_id), do: {:error, {:signer, {:missing_id, "infCte"}}}

  defp tp_amb(tp) when tp in ["1", "2"], do: {:ok, tp}
  defp tp_amb(_tp), do: {:error, :invalid_tp_amb}

  defp splice(xml, qr) do
    supl = "<infCTeSupl><qrCodCTe>" <> escape(qr) <> "</qrCodCTe></infCTeSupl>"

    case Regex.run(@signature, xml, return: :index) || Regex.run(@root_close, xml, return: :index) do
      [{at, _length} | _] ->
        {:ok, binary_part(xml, 0, at) <> supl <> binary_part(xml, at, byte_size(xml) - at)}

      nil ->
        {:error, {:xml, :no_root}}
    end
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
