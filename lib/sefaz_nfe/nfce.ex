defmodule SefazNfe.NFCe do
  @moduledoc """
  The NFC-e (model 65) pieces that are not plain transport: `infNFeSupl` and
  the on-line QR code, version 3.00 (NT 2025.001).

  ## QR code 3.00

  Version 3.00 dropped the CSC, its id token and the hash, so an on-line QR
  code is a pure function of the document:

      {qr_url}?p={chNFe}|3|{tpAmb}

  `qr_url` is always the emitting UF's own address
  (`SefazNfe.Endpoints.qr_code_url/2`), also where SVRS authorizes. A host that
  still builds version 2 with a CSC puts its own `infNFeSupl` in the XML, and
  `put_supl/3` leaves such a document exactly as it is.

  ## Off-line (tpEmis 9)

  Not supported: the off-line QR code embeds the issue day, the total, the
  recipient and the document's own digest value, and is only meaningful
  together with the contingency flow (AD-005, planned for Phase 1). Without an
  `infNFeSupl` of the host's own it is `{:error, {:unsupported, :offline_qr_code}}`
  rather than a QR code SEFAZ would reject as a schema failure.

  ## Placement and escaping

  `infNFeSupl` is a child of `NFe`, after `infNFe` and before `Signature`. It
  is not covered by the signature, whose only `Reference` is `infNFe`'s `Id`,
  so it is spliced into the already signed bytes immediately before
  `<Signature`, by byte offset (`:binary.match/2`) — never by grapheme, which
  an accent earlier in the document would shift (AD-011, CHANGELOG 0.1.1).
  The text is XML-escaped (`&`, `<`, `>`): the `|`, `?` and `=` the QR code is
  made of need none, but a published address may carry an ampersand and
  `qrCode` is element text, not CDATA.
  """

  alias SefazNfe.Endpoints
  alias SefazNfe.XML

  @supl ~r/<(?:[\w.-]+:)?infNFeSupl[\s>]/

  @doc """
  Makes sure the NFC-e `xml` carries an `infNFeSupl`.

  `uf` is the emitting UF, which selects the QR code and `urlChave` addresses,
  and `environment` selects between the production and homologation tables.
  The key and `tpAmb` come from the document itself.

  Works on a signed or an unsigned document; the element goes before
  `<Signature` when there is one, and before `</NFe>` otherwise.
  """
  @spec put_supl(String.t(), String.t() | atom(), Endpoints.environment()) ::
          {:ok, String.t()} | {:error, term()}
  def put_supl(xml, uf, environment) when is_binary(xml) do
    if Regex.match?(@supl, xml) do
      {:ok, xml}
    else
      with {:ok, doc} <- XML.parse(xml),
           :ok <- online(XML.text(doc, "tpEmis")),
           {:ok, key} <- access_key(XML.attribute(doc, "infNFe", "Id")),
           {:ok, tp_amb} <- tp_amb(XML.text(doc, "tpAmb")),
           {:ok, qr_url} <- Endpoints.qr_code_url(uf, environment),
           {:ok, url_chave} <- Endpoints.url_chave(uf, environment) do
        splice(xml, supl(qr_url, key, tp_amb, url_chave))
      end
    end
  end

  @doc """
  The version 3.00 on-line QR code text.

  `?p=` is appended unless the address already carries it.
  """
  @spec qr_code(String.t(), String.t(), String.t()) :: String.t()
  def qr_code(qr_url, key, tp_amb) do
    base = if String.contains?(qr_url, "?p="), do: qr_url, else: qr_url <> "?p="

    base <> key <> "|3|" <> tp_amb
  end

  defp supl(qr_url, key, tp_amb, url_chave) do
    "<infNFeSupl><qrCode>" <>
      escape(qr_code(qr_url, key, tp_amb)) <>
      "</qrCode><urlChave>" <> escape(url_chave) <> "</urlChave></infNFeSupl>"
  end

  defp online("1"), do: :ok
  defp online("9"), do: {:error, {:unsupported, :offline_qr_code}}
  defp online(other), do: {:error, {:unsupported, {:tp_emis, other}}}

  defp access_key("NFe" <> key) when byte_size(key) == 44, do: {:ok, key}
  defp access_key(_id), do: {:error, {:nfce, :invalid_id}}

  defp tp_amb(tp) when tp in ["1", "2"], do: {:ok, tp}
  defp tp_amb(_tp), do: {:error, {:nfce, :invalid_tp_amb}}

  # `:binary.match/2` answers in bytes, which is what `binary_part/3` takes.
  defp splice(xml, supl) do
    case insertion_point(xml) do
      {:ok, at} ->
        {:ok, binary_part(xml, 0, at) <> supl <> binary_part(xml, at, byte_size(xml) - at)}

      :error ->
        {:error, {:nfce, :missing_nfe}}
    end
  end

  defp insertion_point(xml) do
    case :binary.match(xml, "<Signature") do
      {at, _length} -> {:ok, at}
      :nomatch -> closing_nfe(:binary.matches(xml, "</NFe>"))
    end
  end

  defp closing_nfe([]), do: :error
  defp closing_nfe(matches), do: {:ok, matches |> List.last() |> elem(0)}

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
