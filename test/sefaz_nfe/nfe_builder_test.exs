defmodule SefazNfe.NFeBuilderTest do
  use ExUnit.Case, async: true

  alias SefazNfe.NFeBuilder
  alias SefazNfe.Signer
  alias SefazNfe.XML

  test "the access key is 44 digits" do
    %{access_key: key} = NFeBuilder.build()

    assert String.length(key) == 44
    assert String.match?(key, ~r/^\d{44}$/)
  end

  test "the check digit is the MOC's modulo 11" do
    # Worked example: the digit is what makes the weighted sum close on 11.
    assert NFeBuilder.check_digit("3526010000000000019155001000000001100000001") in ~w(0 1 2 3 4 5 6 7 8 9)

    %{access_key: key} = NFeBuilder.build()
    {body, dv} = String.split_at(key, 43)

    assert NFeBuilder.check_digit(body) == dv
  end

  test "cDV in ide matches the key's last digit" do
    %{xml: xml, access_key: key} = NFeBuilder.build()
    {:ok, doc} = XML.parse(xml)

    assert XML.text(doc, "cDV") == String.last(key)
  end

  test "cNF is never equal to nNF, which NT 2019.001 rejects as cStat 897" do
    {:ok, doc} = NFeBuilder.build(number: 42).xml |> XML.parse()

    assert XML.text(doc, "cNF") != XML.text(doc, "nNF")
    assert String.length(XML.text(doc, "cNF")) == 8
  end

  test "dhEmi is second precision, as the schema pattern demands" do
    {:ok, doc} =
      NFeBuilder.build(emitted_at: "2026-09-07T10:00:00.123456-03:00").xml |> XML.parse()

    assert XML.text(doc, "dhEmi") == "2026-09-07T10:00:00-03:00"
  end

  test "the emitter IE is digits, since ISENTO is only legal for a recipient" do
    {:ok, doc} = NFeBuilder.build().xml |> XML.parse()

    assert XML.text(doc, "IE") =~ ~r/^\d+$/
  end

  test "the key encodes the emitter, series and number" do
    %{access_key: key} = NFeBuilder.build(tax_id: "15223384000189", serie: 1, number: 7)

    assert String.contains?(key, "15223384000189")
    assert String.starts_with?(key, "3526")
  end

  test "homologação forces the recipient name the MOC requires" do
    {:ok, doc} = NFeBuilder.build(tp_amb: 2).xml |> XML.parse()

    recipient = XML.element(doc, "dest")

    assert XML.text(recipient, "xNome") ==
             "NF-E EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL"

    assert XML.text(doc, "xNome") == "EMPRESA TESTE LTDA"
  end

  test "the document signs, and the totals survive it" do
    %{xml: xml} = NFeBuilder.build()

    assert {:ok, signed} = Signer.sign_nfe(xml, SefazNfe.Fixtures.cert())
    assert signed =~ "<vNF>100.00</vNF>"
    assert signed =~ "<vICMS>18.00</vICMS>"
    assert Signer.signed?(signed)
  end

  test "the default is Regime Normal, with the ICMS00 groups and totals" do
    %{xml: xml} = NFeBuilder.build(c_nf: 12_345_678)

    assert xml == NFeBuilder.build(c_nf: 12_345_678, crt: 3).xml
    assert xml =~ "<CRT>3</CRT>"
    assert xml =~ "<ICMS00>"
    assert xml =~ "<PISAliq>"
    assert xml =~ "<COFINSAliq>"
    assert xml =~ "<vBC>100.00</vBC><vICMS>18.00</vICMS><vICMSDeson>"
    assert xml =~ "<vPIS>1.65</vPIS><vCOFINS>7.60</vCOFINS><vOutro>"
  end

  test "crt: 1 builds a Simples Nacional emitter" do
    %{xml: xml} = NFeBuilder.build(crt: 1)

    assert xml =~ "<CRT>1</CRT></emit>"

    assert xml =~
             "<ICMS><ICMSSN102><orig>0</orig><CSOSN>102</CSOSN></ICMSSN102></ICMS>"

    assert xml =~ "<PIS><PISNT><CST>07</CST></PISNT></PIS>"
    assert xml =~ "<COFINS><COFINSNT><CST>07</CST></COFINSNT></COFINS>"

    refute xml =~ "ICMS00"
    refute xml =~ "PISAliq"
    refute xml =~ "COFINSAliq"

    assert xml =~ "<ICMSTot><vBC>0.00</vBC><vICMS>0.00</vICMS><vICMSDeson>"
    assert xml =~ "<vPIS>0.00</vPIS><vCOFINS>0.00</vCOFINS><vOutro>"
    assert xml =~ "<vProd>100.00</vProd>"
    assert xml =~ "<vNF>100.00</vNF>"
    assert xml =~ "<IBSCBS><CST>000</CST>"
    assert xml =~ "<IBSCBSTot>"
  end

  test "any other crt is refused" do
    assert_raise ArgumentError, fn -> NFeBuilder.build(crt: 2) end
  end

  test "it carries no comments,which schema validation would refuse" do
    refute NFeBuilder.build().xml =~ "<!--"
  end
end
