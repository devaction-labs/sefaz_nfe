defmodule SefazNfe.ProcTest do
  @moduledoc """
  The `nfeProc` is the document that gets archived and delivered. It is the
  signed NF-e plus its protocol, and both halves have to survive byte for
  byte — the signature covers the document exactly as sent.

  `async: false` because the authorize/1 case swaps `:sefaz_nfe, :soap`, which
  every other test reads.
  """

  use ExUnit.Case, async: false

  alias SefazNfe.Result

  @signed ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
            ~s(<NFe xmlns="http://www.portalfiscal.inf.br/nfe">) <>
            ~s(<infNFe Id="NFe35" versao="4.00"><total><vNF>100.00</vNF></total></infNFe>) <>
            ~s(<Signature xmlns="http://www.w3.org/2000/09/xmldsig#"><SignatureValue>abc</SignatureValue></Signature>) <>
            ~s(</NFe>)

  @envelope_open ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
                   ~s(<retEnviNFe xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">)
  @envelope_close ~s(</retEnviNFe></soap:Body></soap:Envelope>)

  @authorized @envelope_open <>
                ~s(<cStat>104</cStat><xMotivo>Lote processado</xMotivo>) <>
                ~s(<protNFe versao="4.00"><infProt><chNFe>35</chNFe><nProt>135</nProt>) <>
                ~s(<cStat>100</cStat><xMotivo>Autorizado o uso da NF-e</xMotivo></infProt></protNFe>) <>
                @envelope_close

  @receipt @envelope_open <>
             ~s(<cStat>103</cStat><xMotivo>Lote recebido</xMotivo><infRec><nRec>351</nRec></infRec>) <>
             @envelope_close

  @rejected @envelope_open <>
              ~s(<cStat>204</cStat><xMotivo>Duplicidade de NF-e</xMotivo>) <>
              @envelope_close

  test "the proc carries both halves, verbatim" do
    proc = Result.proc(@signed, @authorized)

    assert proc =~ ~s(<infNFe Id="NFe35" versao="4.00">)
    assert proc =~ "<vNF>100.00</vNF>"
    assert proc =~ "<SignatureValue>abc</SignatureValue>"
    assert proc =~ "<nProt>135</nProt>"
  end

  test "it is a well-formed nfeProc in the NF-e namespace" do
    proc = Result.proc(@signed, @authorized)

    assert String.starts_with?(proc, ~s(<?xml version="1.0" encoding="UTF-8"?>))
    assert proc =~ ~s(<nfeProc xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">)
    assert String.ends_with?(proc, "</nfeProc>")
    assert {:ok, _doc} = SefazNfe.XML.parse(proc)
  end

  test "the inner document keeps no XML declaration of its own" do
    proc = Result.proc(@signed, @authorized)

    assert length(String.split(proc, "<?xml")) == 2
  end

  test "there is no proc without a protocol" do
    assert Result.proc(@signed, @receipt) == nil
  end

  test "a rejection has nothing to assemble either" do
    assert Result.proc(@signed, @rejected) == nil
  end

  describe "through authorize/1" do
    setup do
      previous = Application.get_env(:sefaz_nfe, :soap)
      on_exit(fn -> Application.put_env(:sefaz_nfe, :soap, previous) end)
      :ok
    end

    defmodule AuthorizedStub do
      @moduledoc false
      @behaviour SefazNfe.SOAP
      @impl SefazNfe.SOAP
      def call(_endpoint, body, _cert, _opts) do
        send(:sefaz_nfe_proc_test, {:sent, IO.iodata_to_binary(body)})

        {:ok,
         ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
           ~s(<retEnviNFe xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">) <>
           ~s(<cStat>104</cStat><xMotivo>Lote processado</xMotivo>) <>
           ~s(<protNFe versao="4.00"><infProt><chNFe>35260100000000000191550010000000011000000017</chNFe>) <>
           ~s(<nProt>135260000000001</nProt><cStat>100</cStat>) <>
           ~s(<xMotivo>Autorizado o uso da NF-e</xMotivo></infProt></protNFe>) <>
           ~s(</retEnviNFe></soap:Body></soap:Envelope>)}
      end
    end

    test "the lote is synchronous: SEFAZ rejects async for a single document" do
      Process.register(self(), :sefaz_nfe_proc_test)
      Application.put_env(:sefaz_nfe, :soap, AuthorizedStub)

      %{xml: xml} = SefazNfe.NFeBuilder.build(tax_id: "00000000000191")

      SefazNfe.authorize(%{
        xml: xml,
        cert: SefazNfe.Fixtures.cert(),
        uf: "SP",
        environment: :homologation
      })

      assert_receive {:sent, sent}
      assert sent =~ "<indSinc>1</indSinc>"
    end

    test "an authorized document comes back ready to archive" do
      Process.register(self(), :sefaz_nfe_proc_test)
      Application.put_env(:sefaz_nfe, :soap, AuthorizedStub)

      %{xml: xml} = SefazNfe.NFeBuilder.build(tax_id: "00000000000191")

      assert {:ok, result} =
               SefazNfe.authorize(%{
                 xml: xml,
                 cert: SefazNfe.Fixtures.cert(),
                 uf: "SP",
                 environment: :homologation
               })

      assert result.status == :authorized
      assert result.n_prot == "135260000000001"

      assert result.signed_xml =~ "<Signature"
      assert result.xml =~ "<nfeProc"
      assert result.xml =~ "<nProt>135260000000001</nProt>"

      # what was archived is what was signed, and what was signed is what was sent
      assert_receive {:sent, sent}
      assert String.contains?(sent, String.replace(result.signed_xml, ~r/^\s*<\?xml[^>]*\?>/, ""))

      assert String.contains?(
               result.xml,
               String.replace(result.signed_xml, ~r/^\s*<\?xml[^>]*\?>/, "")
             )
    end
  end
end
