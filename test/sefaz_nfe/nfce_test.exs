defmodule SefazNfe.NFCeTest do
  use ExUnit.Case, async: true

  alias SefazNfe.Endpoints
  alias SefazNfe.Fixtures
  alias SefazNfe.NFCe
  alias SefazNfe.NFeBuilder
  alias SefazNfe.Signer
  alias SefazNfe.XML

  defp built(opts \\ []) do
    NFeBuilder.build([model: 65, uf: "BA", uf_code: 29, c_nf: 12_345_678] ++ opts)
  end

  defp signed(xml) do
    {:ok, signed} = Signer.sign_nfe(xml, Fixtures.cert())
    signed
  end

  describe "put_supl/3" do
    test "inserts the on-line QR code 3.00 and urlChave, byte for byte" do
      %{xml: xml, access_key: key} = built()
      signed = signed(xml)

      assert {:ok, result} = NFCe.put_supl(signed, "BA", :homologation)

      supl =
        "<infNFeSupl><qrCode>http://hnfe.sefaz.ba.gov.br/servicos/nfce/qrcode.aspx?p=#{key}|3|2" <>
          "</qrCode><urlChave>http://hinternet.sefaz.ba.gov.br/nfce/consulta</urlChave></infNFeSupl>"

      {at, _length} = :binary.match(signed, "<Signature")

      assert result ==
               binary_part(signed, 0, at) <>
                 supl <> binary_part(signed, at, byte_size(signed) - at)
    end

    test "sits after infNFe and before Signature, outside what the signature covers" do
      {:ok, result} = built() |> Map.fetch!(:xml) |> signed() |> NFCe.put_supl("SP", :production)

      assert result =~ "</infNFe><infNFeSupl><qrCode>"
      assert result =~ "</infNFeSupl><Signature"
    end

    test "removing the element gives back the signed document untouched" do
      signed = signed(built().xml)
      {:ok, result} = NFCe.put_supl(signed, "SP", :homologation)

      [head, rest] = String.split(result, "<infNFeSupl>", parts: 2)
      [_supl, tail] = String.split(rest, "</infNFeSupl>", parts: 2)

      assert head <> tail == signed
    end

    test "takes tpAmb from the document and the addresses from the emitting UF" do
      %{xml: xml, access_key: key} = built(tp_amb: 1, uf: "SP", uf_code: 35)
      {:ok, qr} = Endpoints.qr_code_url("SP", :production)
      {:ok, chave} = Endpoints.url_chave("SP", :production)

      {:ok, result} = xml |> signed() |> NFCe.put_supl("SP", :production)

      assert result =~ "<qrCode>#{qr}?p=#{key}|3|1</qrCode>"
      assert result =~ "<urlChave>#{chave}</urlChave>"
    end

    test "the result is well-formed and the element is where XML says it is" do
      {:ok, result} = built().xml |> signed() |> NFCe.put_supl("BA", :homologation)

      assert {:ok, doc} = XML.parse(result)
      assert XML.text(doc, "qrCode") =~ ~r/\?p=\d{44}\|3\|2$/
      assert XML.text(doc, "urlChave") == "http://hinternet.sefaz.ba.gov.br/nfce/consulta"
    end

    test "an accent before the splice point still gives well-formed XML" do
      %{xml: xml} = built()
      accented = String.replace(xml, "EMPRESA TESTE LTDA", "MÓVEIS NOGUEIRA AÇÚCAR LTDA")
      assert accented != xml

      signed = signed(accented)
      assert {:ok, result} = NFCe.put_supl(signed, "BA", :homologation)

      assert {:ok, doc} = XML.parse(result)
      assert XML.text(doc, "xNome") == "MÓVEIS NOGUEIRA AÇÚCAR LTDA"
      assert result =~ "</infNFe><infNFeSupl>"
      assert result =~ "</infNFeSupl><Signature"
      assert String.valid?(result)
    end

    test "a document that already has infNFeSupl is returned exactly as it is" do
      signed = signed(built().xml)

      host =
        String.replace(
          signed,
          "<Signature",
          "<infNFeSupl><qrCode>https://exemplo.sefaz.ba.gov.br/qr?chNFe=1&amp;nVersao=100</qrCode>" <>
            "<urlChave>http://exemplo.sefaz.ba.gov.br/c</urlChave></infNFeSupl><Signature",
          global: false
        )

      assert {:ok, ^host} = NFCe.put_supl(host, "BA", :homologation)
    end

    test "is idempotent" do
      signed = signed(built().xml)
      {:ok, once} = NFCe.put_supl(signed, "BA", :homologation)

      assert {:ok, ^once} = NFCe.put_supl(once, "BA", :homologation)
    end

    test "an unsigned document gets it before the closing NFe" do
      %{xml: xml} = built()

      assert {:ok, result} = NFCe.put_supl(xml, "BA", :homologation)
      assert result =~ "</infNFe><infNFeSupl><qrCode>"
      assert String.ends_with?(result, "</infNFeSupl></NFe>")
    end

    test "tpEmis 9 without an infNFeSupl of its own is refused by name" do
      %{xml: xml} = built()
      offline = String.replace(xml, "<tpEmis>1</tpEmis>", "<tpEmis>9</tpEmis>")

      assert {:error, {:unsupported, :offline_qr_code}} =
               offline |> signed() |> NFCe.put_supl("BA", :homologation)
    end

    test "tpEmis 9 with the host's own infNFeSupl is left alone" do
      %{xml: xml} = built()

      offline =
        xml
        |> String.replace("<tpEmis>1</tpEmis>", "<tpEmis>9</tpEmis>")
        |> String.replace(
          "</infNFe>",
          "</infNFe><infNFeSupl><qrCode>x</qrCode><urlChave>y</urlChave></infNFeSupl>"
        )

      assert {:ok, ^offline} = NFCe.put_supl(offline, "BA", :homologation)
    end

    test "an unknown UF is an endpoint error, not a crash" do
      signed = signed(built().xml)

      assert {:error, {:unknown_endpoint, "XX", :qr_code}} =
               NFCe.put_supl(signed, "XX", :homologation)
    end
  end

  # A fake CSC, obviously not a real one. The literals below were derived by
  # hand with NFePHP's `QRCode::get200` rules: seq = fields joined by "|", hash
  # = upper-case hex SHA-1 of seq <> CSC, text = url <> "?p=" <> seq <> "|" <> hash,
  # using
  #
  #     printf '%s' "$SEQ$CSC" | sha1sum | tr a-f A-F
  #     printf '%s' "$DIGEST_VALUE" | od -An -tx1 | tr -d ' \n'
  #
  # for the hash and for the hex of the DigestValue text.
  @csc "0123456789ABCDEF0123456789ABCDEF0123"
  @fixed_key "43261112345678000195650010000000011123456780"
  @fixed_digest "Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MD0="
  @fixed_digest_hex "5a6d3976596d4679596d4636635856344d54497a4e4455324e7a67354d44303d"
  @ba_qr "http://hnfe.sefaz.ba.gov.br/servicos/nfce/qrcode.aspx?p="

  defp fixed_doc(tp_emis \\ "1") do
    ~s(<NFe xmlns="http://www.portalfiscal.inf.br/nfe"><infNFe Id="NFe#{@fixed_key}" versao="4.00">) <>
      ~s(<ide><tpAmb>2</tpAmb><tpEmis>#{tp_emis}</tpEmis><dhEmi>2026-11-05T23:59:00-03:00</dhEmi></ide>) <>
      ~s(<total><ICMSTot><vNF>123.4</vNF></ICMSTot></total></infNFe>) <>
      ~s(<Signature xmlns="http://www.w3.org/2000/09/xmldsig#"><SignedInfo><Reference URI="#NFe#{@fixed_key}">) <>
      ~s(<DigestValue>#{@fixed_digest}</DigestValue></Reference></SignedInfo></Signature></NFe>)
  end

  defp qr_code_of(xml) do
    {:ok, doc} = XML.parse(xml)
    XML.text(doc, "qrCode")
  end

  describe "put_supl/4 with QR code 2.00" do
    test "on-line, against a literal derived by hand" do
      assert {:ok, result} =
               NFCe.put_supl(fixed_doc(), "BA", :homologation,
                 qr_code_version: 2,
                 csc: @csc,
                 csc_id: 1
               )

      assert qr_code_of(result) ==
               @ba_qr <> @fixed_key <> "|2|2|1|BCF6A25FC2BAD96250D1E958A4D46A35556DC375"
    end

    test "on-line, cross-checked with :crypto and with the idCSC zeros stripped" do
      seq = "#{@fixed_key}|2|2|7"
      hash = :sha |> :crypto.hash(seq <> @csc) |> Base.encode16(case: :upper)

      for id <- ["000007", "7", 7] do
        {:ok, result} =
          NFCe.put_supl(fixed_doc(), "BA", :homologation,
            qr_code_version: 2,
            csc: @csc,
            csc_id: id
          )

        assert qr_code_of(result) == @ba_qr <> seq <> "|" <> hash
      end
    end

    test "off-line, against a literal derived by hand: day, vNF and hex of the digest" do
      assert {:ok, result} =
               NFCe.put_supl(fixed_doc("9"), "BA", :homologation,
                 qr_code_version: 2,
                 csc: @csc,
                 csc_id: 1
               )

      assert qr_code_of(result) ==
               @ba_qr <>
                 "#{@fixed_key}|2|2|05|123.40|#{@fixed_digest_hex}|1|" <>
                 "786E89A7D0971660D2905BF21451EDB0C3E243EB"
    end

    test "off-line, cross-checked with :crypto" do
      seq = "#{@fixed_key}|2|2|05|123.40|#{Base.encode16(@fixed_digest, case: :lower)}|1"
      hash = :sha |> :crypto.hash(seq <> @csc) |> Base.encode16(case: :upper)

      {:ok, result} =
        NFCe.put_supl(fixed_doc("9"), "BA", :homologation,
          qr_code_version: 2,
          csc: @csc,
          csc_id: 1
        )

      assert qr_code_of(result) == @ba_qr <> seq <> "|" <> hash
    end

    test "off-line takes the digest from a really signed document" do
      %{xml: xml} = built()
      offline = String.replace(xml, "<tpEmis>1</tpEmis>", "<tpEmis>9</tpEmis>")
      signed = signed(offline)
      [_all, digest] = Regex.run(~r{<DigestValue>([^<]+)</DigestValue>}, signed)

      assert {:ok, result} =
               NFCe.put_supl(signed, "BA", :homologation,
                 qr_code_version: 2,
                 csc: @csc,
                 csc_id: 1
               )

      assert qr_code_of(result) =~ "|#{Base.encode16(digest, case: :lower)}|1|"
      assert result =~ "</infNFe><infNFeSupl><qrCode>"
      assert result =~ "</infNFeSupl><Signature"
    end

    test "off-line on a document with no signature is refused by name" do
      %{xml: xml} = built()
      offline = String.replace(xml, "<tpEmis>1</tpEmis>", "<tpEmis>9</tpEmis>")

      assert {:error, {:nfce, :missing_digest_value}} =
               NFCe.put_supl(offline, "BA", :homologation,
                 qr_code_version: 2,
                 csc: @csc,
                 csc_id: 1
               )
    end

    test "a missing CSC or id is named, and no value is in the error" do
      doc = fixed_doc()

      assert {:error, {:missing_csc, [:csc, :csc_id]}} =
               NFCe.put_supl(doc, "BA", :homologation, qr_code_version: 2)

      assert {:error, {:missing_csc, [:csc_id]}} =
               NFCe.put_supl(doc, "BA", :homologation, qr_code_version: 2, csc: @csc)

      assert {:error, {:missing_csc, [:csc]}} =
               NFCe.put_supl(doc, "BA", :homologation, qr_code_version: 2, csc_id: 1)

      for bad <- ["abc", "0", 0, nil, ""] do
        assert {:error, {:missing_csc, [:csc_id]} = error} =
                 NFCe.put_supl(doc, "BA", :homologation,
                   qr_code_version: 2,
                   csc: @csc,
                   csc_id: bad
                 )

        refute inspect(error) =~ @csc
      end
    end

    test "an unknown version is refused" do
      assert {:error, {:unsupported, {:qr_code_version, 4}}} =
               NFCe.put_supl(fixed_doc(), "BA", :homologation, qr_code_version: 4)
    end

    test "version 3 is the default, ignores the CSC and still refuses off-line" do
      {:ok, default} = NFCe.put_supl(fixed_doc(), "BA", :homologation)
      {:ok, with_csc} = NFCe.put_supl(fixed_doc(), "BA", :homologation, csc: @csc, csc_id: 1)

      assert qr_code_of(default) == @ba_qr <> @fixed_key <> "|3|2"
      assert with_csc == default

      assert {:error, {:unsupported, :offline_qr_code}} =
               NFCe.put_supl(fixed_doc("9"), "BA", :homologation,
                 qr_code_version: 3,
                 csc: @csc,
                 csc_id: 1
               )
    end

    test "a host infNFeSupl is still left alone" do
      supl = "<infNFeSupl><qrCode>q</qrCode><urlChave>u</urlChave></infNFeSupl>"
      host = String.replace(fixed_doc(), "<Signature", supl <> "<Signature")

      assert {:ok, ^host} = NFCe.put_supl(host, "BA", :homologation, qr_code_version: 2)
    end
  end

  describe "qr_code/3" do
    test "appends ?p= once" do
      key = String.duplicate("1", 44)

      assert NFCe.qr_code("http://x.gov.br/qr", key, "2") == "http://x.gov.br/qr?p=#{key}|3|2"
      assert NFCe.qr_code("http://x.gov.br/qr?p=", key, "1") == "http://x.gov.br/qr?p=#{key}|3|1"
    end
  end

  # xmerl cannot compile the current PL_010 schema package (it leaves the RTC
  # simple types undeclared), so the oracle is xmllint, and the test is skipped
  # on a machine without it or without the unpacked schemas.
  describe "against the real PL_010 schema (xmllint)" do
    @schemas "/home/alex/PhpstormProjects/fiscal-gateway/vendor/nfephp-org/sped-nfe/schemes/PL_010_V1.30"
    @skip if(File.dir?(@schemas) and System.find_executable("xmllint"),
            do: false,
            else: "xmllint or the PL_010 schemas are not available"
          )

    @tag skip: @skip
    test "the model 65 builder output, signed and with infNFeSupl, validates" do
      for opts <- [[], [crt: 1], [dest_tax_id: "00000000191"], [tp_amb: 1]] do
        {:ok, xml} = built(opts).xml |> signed() |> NFCe.put_supl("BA", :homologation)
        assert xmllint(xml) == :ok, inspect(opts)
      end
    end

    # The PL_010 qrCode pattern only has the off-line shape of version 3.00, so
    # an off-line 2.00 text is rejected by this schema; the on-line one passes.
    @tag skip: @skip
    test "QR code 2.00 on-line validates" do
      opts = [qr_code_version: 2, csc: "0123456789ABCDEF0123456789ABCDEF0123", csc_id: 1]
      {:ok, result} = built().xml |> signed() |> NFCe.put_supl("BA", :homologation, opts)

      assert :ok == xmllint(result)
    end

    @tag skip: @skip
    test "the model 55 builder output still validates" do
      assert xmllint(signed(NFeBuilder.build().xml)) == :ok
    end

    defp xmllint(xml) do
      file = Path.join(System.tmp_dir!(), "nfce_#{System.unique_integer([:positive])}.xml")
      File.write!(file, xml)

      try do
        case System.cmd("xmllint", ["--noout", "--schema", "nfe_v4.00.xsd", file],
               cd: @schemas,
               stderr_to_stdout: true
             ) do
          {_output, 0} -> :ok
          {output, _status} -> output
        end
      after
        File.rm(file)
      end
    end
  end
end
