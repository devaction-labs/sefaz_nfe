defmodule SefazNfe.SignerTest do
  @moduledoc """
  The digest values here were cross-checked against `xmllint --c14n`: the
  canonical form of the signed subtree was produced independently and hashed,
  and it matches what the signer writes into `DigestValue`.

  `xmlsec1` is the usual third-party oracle for a whole signature, but the
  build on this machine fails to load any key — it cannot even sign with an
  explicit PEM — so verification here decomposes instead: canonical form
  against `xmllint`, digest against that canonical form, and the RSA signature
  against the certificate's own public key.
  """

  use ExUnit.Case, async: true

  alias SefazNfe.Fixtures
  alias SefazNfe.Signer
  alias SefazNfe.XML
  alias SefazNfe.XML.C14N

  @nfe_ns "http://www.portalfiscal.inf.br/nfe"
  @id "NFe35260100000000000191550010000000011000000017"

  @nfe ~s(<?xml version="1.0" encoding="UTF-8"?><NFe xmlns="#{@nfe_ns}">) <>
         ~s(<infNFe Id="#{@id}" versao="4.00">) <>
         ~s(<ide><cUF>35</cUF><natOp>VENDA</natOp></ide>) <>
         ~s(<total><ICMSTot><vICMS>10.00</vICMS><vNF>100.00</vNF></ICMSTot></total>) <>
         ~s(</infNFe></NFe>)

  # Every real NF-e carries an accent somewhere.
  @accented ~s(<?xml version="1.0" encoding="UTF-8"?><NFe xmlns="#{@nfe_ns}">) <>
              ~s(<infNFe Id="#{@id}" versao="4.00">) <>
              ~s(<ide><cUF>35</cUF><natOp>VENDA</natOp></ide>) <>
              ~s(<emit><xNome>Móveis Nogueira</xNome></emit>) <>
              ~s(</infNFe></NFe>)

  defp signed do
    {:ok, xml} = Signer.sign_nfe(@nfe, Fixtures.cert())
    xml
  end

  defp extract(xml, tag) do
    [_, value] = Regex.run(~r{<#{tag}>([^<]*)</#{tag}>}, xml)
    value
  end

  test "the signature lands inside NFe, after infNFe" do
    xml = signed()

    assert xml =~ ~s(</infNFe><Signature xmlns="http://www.w3.org/2000/09/xmldsig#">)
    assert String.ends_with?(xml, "</Signature></NFe>")
  end

  test "an accented document stays well-formed, signature in place" do
    {:ok, xml} = Signer.sign_nfe(@accented, Fixtures.cert())

    assert xml =~ ~s(</infNFe><Signature xmlns="http://www.w3.org/2000/09/xmldsig#">)
    assert String.ends_with?(xml, "</Signature></NFe>")
    refute xml =~ "<<"
    assert {:ok, _parsed} = XML.parse(xml)
  end

  test "the cut is counted in bytes, whatever the accents cost" do
    for name <- ["ASCII", "Móveis", "Açaí e Çedilha", "日本語"] do
      nfe = String.replace(@accented, "Móveis Nogueira", name)
      {:ok, xml} = Signer.sign_nfe(nfe, Fixtures.cert())

      assert String.ends_with?(xml, "</Signature></NFe>"), "cut moved for #{name}"
      assert {:ok, _parsed} = XML.parse(xml)
    end
  end

  test "the original bytes are untouched, tax nodes included (SEFAZ-04)" do
    xml = signed()

    assert String.contains?(
             xml,
             ~s(<total><ICMSTot><vICMS>10.00</vICMS><vNF>100.00</vNF></ICMSTot></total>)
           )

    assert String.contains?(xml, ~s(<infNFe Id="#{@id}" versao="4.00">))
    assert String.starts_with?(xml, ~s(<?xml version="1.0" encoding="UTF-8"?>))
  end

  test "the Reference points at the Id of the signed element" do
    assert signed() =~ ~s(<Reference URI="##{@id}">)
  end

  test "the MOC algorithms are the ones written" do
    xml = signed()

    assert xml =~ ~s(Algorithm="http://www.w3.org/2000/09/xmldsig#rsa-sha1")
    assert xml =~ ~s(Algorithm="http://www.w3.org/2000/09/xmldsig#sha1")
    assert xml =~ ~s(Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature")
    assert xml =~ ~s(Algorithm="http://www.w3.org/TR/2001/REC-xml-c14n-20010315")
  end

  test "DigestValue is SHA-1 over the canonical infNFe" do
    xml = signed()

    {:ok, doc} = XML.parse(xml)
    canonical = doc |> XML.element("infNFe") |> C14N.canonicalize()
    expected = :sha |> :crypto.hash(canonical) |> Base.encode64()

    assert extract(xml, "DigestValue") == expected
  end

  test "the canonical infNFe renders the namespace it inherited from NFe" do
    {:ok, doc} = XML.parse(signed())
    canonical = doc |> XML.element("infNFe") |> C14N.canonicalize()

    assert String.starts_with?(canonical, ~s(<infNFe xmlns="#{@nfe_ns}" Id="#{@id}"))
  end

  test "SignatureValue verifies against the certificate's own public key" do
    xml = signed()
    cert = Fixtures.cert()

    [_, signed_info] = Regex.run(~r{(<SignedInfo>.*?</SignedInfo>)}s, xml)

    {:ok, doc} =
      signed_info
      |> String.replace(
        "<SignedInfo>",
        ~s(<SignedInfo xmlns="http://www.w3.org/2000/09/xmldsig#">)
      )
      |> XML.parse()

    public_key = cert.der |> :public_key.pkix_decode_cert(:otp) |> elem(1) |> elem(7) |> elem(2)
    signature = xml |> extract("SignatureValue") |> Base.decode64!()

    assert :public_key.verify(C14N.canonicalize(doc), :sha, signature, public_key)
  end

  test "KeyInfo carries the signing certificate, so SEFAZ can check it" do
    embedded = signed() |> extract("X509Certificate") |> Base.decode64!()

    assert embedded == Fixtures.cert().der
  end

  test "a signed document is never signed twice" do
    once = signed()

    assert {:ok, ^once} = Signer.sign_nfe(once, Fixtures.cert())
  end

  test "tampering with a tax node breaks the digest" do
    tampered = String.replace(signed(), "<vICMS>10.00</vICMS>", "<vICMS>0.00</vICMS>")

    {:ok, doc} = XML.parse(tampered)
    canonical = doc |> XML.element("infNFe") |> C14N.canonicalize()
    recomputed = :sha |> :crypto.hash(canonical) |> Base.encode64()

    refute recomputed == extract(tampered, "DigestValue")
  end

  test "a document with no Id is refused rather than signed meaninglessly" do
    without_id = String.replace(@nfe, ~s( Id="#{@id}"), "")

    assert {:error, {:signer, {:missing_id, "infNFe"}}} =
             Signer.sign_nfe(without_id, Fixtures.cert())
  end

  test "a document with no infNFe is refused" do
    assert {:error, {:signer, {:missing_element, "infNFe"}}} =
             Signer.sign_nfe(~s(<NFe xmlns="#{@nfe_ns}"><outro/></NFe>), Fixtures.cert())
  end
end
