defmodule SefazNfe.MDFe.QRCode do
  @moduledoc """
  `infMDFeSupl` with `qrCodMDFe`, which an MDF-e 3.00 must carry.

  The text is the SVRS portal address with the key and the environment:

      {base}?chMDFe={chMDFe}&tpAmb={tpAmb}

  `base` is data (`qr_code` of `priv/endpoints/mdfe_3.00.json`, see
  `SefazNfe.Endpoints.mdfe_qr_code_url/1`). In off-line contingency (`tpEmis` 2)
  the emitter also signs the key and the text gains `&sign={base64}`: the
  RSA-SHA1 signature, with the certificate's key, of the 44 digit key as text
  (NFePHP `Factories\\QRCode`: `base64_encode($certificate->sign($chMDFe))`). The
  base64 is not URL-encoded, as NFePHP does and the XSD pattern allows.

  The element goes after `infMDFe` and before `Signature`; it is not covered by
  the signature, whose only `Reference` is `infMDFe`'s `Id`, so it is spliced
  into the already signed bytes by byte offset (AD-011). A document that
  already has an `infMDFeSupl` is returned as it is.
  """

  alias SefazNfe.Certificate
  alias SefazNfe.Endpoints
  alias SefazNfe.XML

  @supl ~r/<(?:[\w.-]+:)?infMDFeSupl[\s>]/

  @doc """
  Adds `infMDFeSupl` to the signed MDF-e `xml`.

  `tpEmis` 1 (normal) and 2 (off-line contingency) are supported; anything else
  is `{:error, {:unsupported, {:tp_emis, value}}}`.
  """
  @spec put_supl(String.t(), Certificate.t(), Endpoints.environment()) ::
          {:ok, String.t()} | {:error, term()}
  def put_supl(xml, %Certificate{} = cert, environment) when is_binary(xml) do
    if Regex.match?(@supl, xml) do
      {:ok, xml}
    else
      with {:ok, doc} <- XML.parse(xml),
           {:ok, key} <- access_key(XML.attribute(doc, "infMDFe", "Id")),
           {:ok, tp_amb} <- tp_amb(XML.text(doc, "tpAmb")),
           {:ok, sign} <- sign(XML.text(doc, "tpEmis"), key, cert),
           {:ok, base} <- Endpoints.mdfe_qr_code_url(environment) do
        splice(xml, supl(qr_code(base, key, tp_amb, sign)))
      end
    end
  end

  @doc """
  The QR code text. `sign` is `nil` for a normal emission, or the base64
  signature of the key for contingency.
  """
  @spec qr_code(String.t(), String.t(), String.t(), String.t() | nil) :: String.t()
  def qr_code(base, key, tp_amb, sign) do
    base <> "?chMDFe=" <> key <> "&tpAmb=" <> tp_amb <> sign_param(sign)
  end

  defp sign_param(nil), do: ""
  defp sign_param(sign), do: "&sign=" <> sign

  defp sign("1", _key, _cert), do: {:ok, nil}
  defp sign("2", key, cert), do: {:ok, sign_key(key, cert)}
  defp sign(other, _key, _cert), do: {:error, {:unsupported, {:tp_emis, other}}}

  defp sign_key(key, cert) do
    private_key = :public_key.der_decode(:PrivateKeyInfo, cert.key)
    key |> :public_key.sign(:sha, private_key) |> Base.encode64()
  end

  defp access_key("MDFe" <> key) when byte_size(key) == 44, do: {:ok, key}
  defp access_key(_id), do: {:error, {:mdfe, :invalid_id}}

  defp tp_amb(tp) when tp in ["1", "2"], do: {:ok, tp}
  defp tp_amb(_tp), do: {:error, {:mdfe, :invalid_tp_amb}}

  defp supl(qr), do: "<infMDFeSupl><qrCodMDFe>" <> escape(qr) <> "</qrCodMDFe></infMDFeSupl>"

  defp splice(xml, supl) do
    case :binary.match(xml, "<Signature") do
      {at, _length} ->
        {:ok, binary_part(xml, 0, at) <> supl <> binary_part(xml, at, byte_size(xml) - at)}

      :nomatch ->
        {:error, {:mdfe, :not_signed}}
    end
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
