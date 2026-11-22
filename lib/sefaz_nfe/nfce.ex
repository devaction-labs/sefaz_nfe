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

  ## QR code 2.00 (CSC)

  Opt in with `qr_code_version: 2`, `csc:` and `csc_id:` (`put_supl/4`). The
  text follows the "Manual de Especificacoes Tecnicas do DANFE NFC-e e QR
  Code" v5, formatted as NFePHP's `QRCode::get200` does:

      on-line:  {qr_url}?p={chNFe}|2|{tpAmb}|{cIdToken}|{hash}
      off-line: {qr_url}?p={chNFe}|2|{tpAmb}|{dd}|{vNF}|{hex(DigestValue)}|{cIdToken}|{hash}

  `hash` is the upper-case hex SHA-1 of everything before it plus the CSC.
  `cIdToken` is the integer, so leading zeros are dropped; `dd` is the day of
  `dhEmi` as written in the document, two digits; `vNF` has two decimals; and
  the digest is the hex of the ASCII text of the base64 `DigestValue` in
  `SignedInfo`, which is why an off-line version 2 needs a signed document.
  Version 2 off-line needs only the CSC, no certificate signature, so for
  version 2 (and only for it) `tpEmis` 9 is supported.

  The CSC is a secret. It is never logged, never part of an error tuple and
  never inspected by this library; do not put it in logs or telemetry on the
  host side either.

  ## Off-line (tpEmis 9), version 3

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

  ## Options

    * `:qr_code_version` - `3` (default) or `2`.
    * `:csc` and `:csc_id` - required for version 2 and ignored for 3. The CSC
      is a string; its id is an integer or a numeric string. Either missing
      gives `{:error, {:missing_csc, fields}}` naming the fields, never values.

  Works on a signed or an unsigned document; the element goes before
  `<Signature` when there is one, and before `</NFe>` otherwise.
  """
  @spec put_supl(String.t(), String.t() | atom(), Endpoints.environment(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def put_supl(xml, uf, environment, opts \\ []) when is_binary(xml) and is_list(opts) do
    if Regex.match?(@supl, xml) do
      {:ok, xml}
    else
      with {:ok, version} <- version(Keyword.get(opts, :qr_code_version, 3)),
           {:ok, doc} <- XML.parse(xml),
           {:ok, tp_emis} <- tp_emis(XML.text(doc, "tpEmis"), version),
           {:ok, csc} <- csc(version, opts),
           {:ok, key} <- access_key(XML.attribute(doc, "infNFe", "Id")),
           {:ok, tp_amb} <- tp_amb(XML.text(doc, "tpAmb")),
           {:ok, qr_url} <- Endpoints.qr_code_url(uf, environment),
           {:ok, url_chave} <- Endpoints.url_chave(uf, environment),
           {:ok, qr} <- build_qr(version, tp_emis, qr_url, key, tp_amb, csc, doc) do
        splice(xml, supl(qr, url_chave))
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

  defp supl(qr, url_chave) do
    "<infNFeSupl><qrCode>" <>
      escape(qr) <>
      "</qrCode><urlChave>" <> escape(url_chave) <> "</urlChave></infNFeSupl>"
  end

  defp version(version) when version in [2, 3], do: {:ok, version}
  defp version(other), do: {:error, {:unsupported, {:qr_code_version, other}}}

  defp tp_emis("1", _version), do: {:ok, :online}
  defp tp_emis("9", 2), do: {:ok, :offline}
  defp tp_emis("9", 3), do: {:error, {:unsupported, :offline_qr_code}}
  defp tp_emis(other, _version), do: {:error, {:unsupported, {:tp_emis, other}}}

  defp csc(3, _opts), do: {:ok, nil}

  defp csc(2, opts) do
    csc = Keyword.get(opts, :csc)
    id = csc_id(Keyword.get(opts, :csc_id))

    case {csc, id} do
      {csc, {:ok, id}} when is_binary(csc) and csc != "" -> {:ok, {csc, id}}
      _missing -> {:error, {:missing_csc, missing_csc(csc, id)}}
    end
  end

  defp missing_csc(csc, id) do
    for {field, present?} <- [csc: is_binary(csc) and csc != "", csc_id: match?({:ok, _}, id)],
        not present?,
        do: field
  end

  # `cIdToken` is the integer: NFePHP casts it with `(int)`, so "000001" is 1.
  defp csc_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp csc_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _other -> :error
    end
  end

  defp csc_id(_id), do: :error

  defp build_qr(3, :online, qr_url, key, tp_amb, _csc, _doc),
    do: {:ok, qr_code(qr_url, key, tp_amb)}

  defp build_qr(2, :online, qr_url, key, tp_amb, {csc, id}, _doc),
    do: {:ok, sealed(qr_url, [key, "2", tp_amb, Integer.to_string(id)], csc)}

  defp build_qr(2, :offline, qr_url, key, tp_amb, {csc, id}, doc) do
    with {:ok, day} <- issue_day(XML.text(doc, "dhEmi")),
         {:ok, total} <- total(XML.text(doc, "vNF")),
         {:ok, digest} <- digest_hex(XML.text(doc, "DigestValue")) do
      {:ok, sealed(qr_url, [key, "2", tp_amb, day, total, digest, Integer.to_string(id)], csc)}
    end
  end

  defp sealed(qr_url, fields, csc) do
    seq = Enum.join(fields, "|")
    hash = :sha |> :crypto.hash(seq <> csc) |> Base.encode16(case: :upper)

    with_query(qr_url) <> seq <> "|" <> hash
  end

  defp with_query(qr_url) do
    if String.contains?(qr_url, "?p="), do: qr_url, else: qr_url <> "?p="
  end

  # The day as the document writes it (`dhEmi` is local time with an offset),
  # which is what PHP's `DateTime::format("d")` gives for that string.
  defp issue_day(dh_emi) when is_binary(dh_emi) do
    case Regex.run(~r/^\d{4}-\d{2}-(0[1-9]|[12]\d|3[01])T/, dh_emi) do
      [_all, day] -> {:ok, day}
      nil -> {:error, {:nfce, :invalid_dh_emi}}
    end
  end

  defp issue_day(_dh_emi), do: {:error, {:nfce, :invalid_dh_emi}}

  # `number_format(vNF, 2, ".", "")`; the XSD allows at most two decimals.
  defp total(value) when is_binary(value) do
    case Regex.run(~r/^(\d+)(?:\.(\d{1,2}))?$/, value) do
      [_all, int] -> {:ok, int <> ".00"}
      [_all, int, frac] -> {:ok, int <> "." <> String.pad_trailing(frac, 2, "0")}
      nil -> {:error, {:nfce, :invalid_v_nf}}
    end
  end

  defp total(_value), do: {:error, {:nfce, :invalid_v_nf}}

  defp digest_hex(digest) when is_binary(digest) and digest != "",
    do: {:ok, Base.encode16(digest, case: :lower)}

  defp digest_hex(_digest), do: {:error, {:nfce, :missing_digest_value}}

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
