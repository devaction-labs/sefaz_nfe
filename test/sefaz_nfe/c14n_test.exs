defmodule SefazNfe.XML.C14NTest do
  @moduledoc """
  Every expected value here was produced by `xmllint --c14n`, the reference
  implementation, and compared byte for byte. A canonicalisation that drifts by
  one byte still yields a well-formed signature — one SEFAZ rejects without
  saying why — so these are golden values, not hand-written guesses.
  """

  use ExUnit.Case, async: true

  alias SefazNfe.XML
  alias SefazNfe.XML.C14N

  defp canonical(xml) do
    {:ok, doc} = XML.parse(xml)
    C14N.canonicalize(doc)
  end

  test "empty elements become a start and end tag pair" do
    assert canonical(~s(<a><b/></a>)) == ~s(<a><b></b></a>)
  end

  test "attributes are sorted by name" do
    assert canonical(~s(<a z="1" m="2" a="3"/>)) == ~s(<a a="3" m="2" z="1"></a>)
  end

  test "prefixed attributes sort after unprefixed, by namespace URI" do
    xml = ~s(<r xmlns:a="urn:A" xmlns:b="urn:B"><c b:x="1" a:y="2" z="3"/></r>)

    assert canonical(xml) ==
             ~s(<r xmlns:a="urn:A" xmlns:b="urn:B"><c z="3" a:y="2" b:x="1"></c></r>)
  end

  test "namespace declarations come first and are sorted by prefix" do
    xml = ~s(<r xmlns:z="urn:Z" xmlns:a="urn:A" xmlns="urn:D"><a:c/></r>)

    assert canonical(xml) ==
             ~s(<r xmlns="urn:D" xmlns:a="urn:A" xmlns:z="urn:Z"><a:c></a:c></r>)
  end

  test "a namespace redeclared identically on a child is dropped" do
    xml = ~s(<a:r xmlns:a="urn:A"><a:c xmlns:a="urn:A"/></a:r>)

    assert canonical(xml) == ~s(<a:r xmlns:a="urn:A"><a:c></a:c></a:r>)
  end

  test "text escapes &, < and >, but leaves quotes alone" do
    assert canonical(~s(<a>&lt;tag&gt; &amp; "aspas"</a>)) ==
             ~s(<a>&lt;tag&gt; &amp; "aspas"</a>)
  end

  test "attribute values escape < and quotes, but not >" do
    assert canonical(~s(<a v="&lt;x&gt; &amp; &quot;q&quot;"/>)) ==
             ~s(<a v="&lt;x> &amp; &quot;q&quot;"></a>)
  end

  test "whitespace inside the document element is content, not noise" do
    assert canonical(~s(<a> <b>  y  </b> </a>)) == ~s(<a> <b>  y  </b> </a>)
  end

  test "accented UTF-8 survives" do
    assert canonical(~s(<a>Serviço em Operação</a>)) == ~s(<a>Serviço em Operação</a>)
  end

  describe "the apex rule" do
    @nfe ~s(<NFe xmlns="http://www.portalfiscal.inf.br/nfe">) <>
           ~s(<infNFe Id="NFe35" versao="4.00"><ide><cUF>35</cUF></ide></infNFe></NFe>)

    test "a signed subtree renders the namespace it only inherited" do
      {:ok, doc} = XML.parse(@nfe)
      inf_nfe = XML.element(doc, "infNFe")

      canonical = C14N.canonicalize(inf_nfe)

      assert canonical ==
               ~s(<infNFe xmlns="http://www.portalfiscal.inf.br/nfe" Id="NFe35" versao="4.00">) <>
                 ~s(<ide><cUF>35</cUF></ide></infNFe>)
    end

    test "the whole document keeps the declaration where it was written" do
      assert canonical(@nfe) == @nfe
    end
  end
end
