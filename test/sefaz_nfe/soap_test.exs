defmodule SefazNfe.SOAPTest do
  use ExUnit.Case, async: false

  alias SefazNfe.Result
  alias SefazNfe.SOAP.Envelope
  alias SefazNfe.XML

  defp soap(inner) do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
      <soap:Body><nfeResultMsg>#{inner}</nfeResultMsg></soap:Body>
    </soap:Envelope>
    """
  end

  describe "Envelope" do
    test "wraps a message in the service's own WSDL namespace" do
      assert {:ok, envelope} = Envelope.wrap(:nfe_status_servico, "<consStatServ/>")

      assert envelope =~ ~s(xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeStatusServico4")
      assert envelope =~ "<soap:Envelope"
      assert envelope =~ "<consStatServ/>"
    end

    test "each service gets its own namespace, which is what routes the call" do
      assert {:ok, a} = Envelope.wrap(:nfe_autorizacao, "<x/>")
      assert {:ok, b} = Envelope.wrap(:nfe_consulta_protocolo, "<x/>")

      assert a =~ "NFeAutorizacao4"
      assert b =~ "NFeConsultaProtocolo4"
      refute a == b
    end

    test "an unknown service is refused rather than sent to a wrong namespace" do
      assert {:error, {:unknown_service, :nope}} = Envelope.wrap(:nope, "<x/>")
    end

    test "the message is passed through byte for byte (SEFAZ-04)" do
      signed = ~s(<NFe><infNFe><vICMS>10.00</vICMS></infNFe><Signature/></NFe>)

      assert {:ok, envelope} = Envelope.wrap(:nfe_autorizacao, signed)
      assert String.contains?(envelope, signed)
    end

    test "tp_amb follows the MOC: 1 production, 2 homologation" do
      assert Envelope.tp_amb(:production) == 1
      assert Envelope.tp_amb(:homologation) == 2
    end

    test "status_service carries tpAmb, cUF and xServ" do
      message = Envelope.status_service(35, 2)

      assert message =~ "<tpAmb>2</tpAmb>"
      assert message =~ "<cUF>35</cUF>"
      assert message =~ "<xServ>STATUS</xServ>"
    end
  end

  describe "Result.parse/1" do
    test "cStat 107 is a service in operation" do
      body =
        soap("""
        <retConsStatServ versao="4.00" xmlns="http://www.portalfiscal.inf.br/nfe">
          <tpAmb>2</tpAmb><cStat>107</cStat><xMotivo>Servico em Operacao</xMotivo>
          <cUF>35</cUF><tMed>1</tMed>
        </retConsStatServ>
        """)

      assert {:ok, result} = Result.parse(body)
      assert result.c_stat == 107
      assert result.status == :rejected
      assert result.x_motivo == "Servico em Operacao"
    end

    test "cStat 100 is authorized, with chave and protocol" do
      body =
        soap("""
        <retEnviNFe xmlns="http://www.portalfiscal.inf.br/nfe">
          <cStat>100</cStat><xMotivo>Autorizado o uso da NF-e</xMotivo>
          <chNFe>35240100000000000191550010000000011000000017</chNFe>
          <nProt>135240000000001</nProt>
        </retEnviNFe>
        """)

      assert {:ok, result} = Result.parse(body)
      assert result.status == :authorized
      assert result.n_prot == "135240000000001"
      assert result.ch_nfe == "35240100000000000191550010000000011000000017"
    end

    test "cStat 103 is a received batch carrying a recibo, not a protocol" do
      body =
        soap("""
        <retEnviNFe xmlns="http://www.portalfiscal.inf.br/nfe">
          <cStat>103</cStat><xMotivo>Lote recebido com sucesso</xMotivo>
          <infRec><nRec>351000000000001</nRec></infRec>
        </retEnviNFe>
        """)

      assert {:ok, result} = Result.parse(body)
      assert result.status == :batch_received
      assert result.n_rec == "351000000000001"
      assert is_nil(result.n_prot)
    end

    test "an event reports its own outcome, not the batch's" do
      body =
        soap("""
        <retEnvEvento versao="1.00" xmlns="http://www.portalfiscal.inf.br/nfe">
          <cStat>128</cStat><xMotivo>Lote de evento processado</xMotivo>
          <retEvento versao="1.00"><infEvento>
            <cStat>135</cStat><xMotivo>Evento registrado e vinculado a NF-e</xMotivo>
            <chNFe>35240100000000000191550010000000011000000017</chNFe>
            <nProt>891240000000001</nProt>
          </infEvento></retEvento>
        </retEnvEvento>
        """)

      assert {:ok, result} = Result.parse(body)
      assert result.c_stat == 135
      assert result.status == :authorized
      assert result.n_prot == "891240000000001"
    end

    test "an event rejection is read from the nested element too" do
      body =
        soap("""
        <retEnvEvento xmlns="http://www.portalfiscal.inf.br/nfe">
          <cStat>128</cStat><xMotivo>Lote de evento processado</xMotivo>
          <retEvento><infEvento>
            <cStat>236</cStat>
            <xMotivo>Rejeicao: Chave de Acesso com digito verificador invalido</xMotivo>
          </infEvento></retEvento>
        </retEnvEvento>
        """)

      assert {:ok, result} = Result.parse(body)
      assert result.c_stat == 236
      assert result.status == :rejected
      assert result.x_motivo =~ "digito verificador"
    end

    test "a rejection is {:ok, _}, never {:error, _} (SEFAZ-03)" do
      body =
        soap("""
        <retEnviNFe xmlns="http://www.portalfiscal.inf.br/nfe">
          <cStat>204</cStat><xMotivo>Rejeicao: Duplicidade de NF-e</xMotivo>
        </retEnviNFe>
        """)

      assert {:ok, result} = Result.parse(body)
      assert result.status == :rejected
      assert result.c_stat == 204
    end

    test "a SOAP fault is a transport failure, never a cStat" do
      body = """
      <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
        <soap:Body><soap:Fault>
          <soap:Code><soap:Value>soap:Receiver</soap:Value></soap:Code>
          <soap:Reason><soap:Text>Erro no processamento</soap:Text></soap:Reason>
        </soap:Fault></soap:Body>
      </soap:Envelope>
      """

      assert {:error, {:soap_fault, reason}} = Result.parse(body)
      assert reason =~ "Erro no processamento"
    end

    test "a body without cStat is an error, not a fabricated result" do
      assert {:error, {:xml, :no_c_stat}} = Result.parse(soap("<retConsStatServ/>"))
    end

    test "garbage is an error, not a crash" do
      assert {:error, {:xml, :malformed}} = Result.parse("<not xml")
    end
  end

  describe "XML safety" do
    test "a DTD is refused before xmerl sees it" do
      xxe = ~s(<!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/passwd">]><r>&x;</r>)

      assert {:error, {:xml, :dtd_forbidden}} = XML.parse(xxe)
    end

    test "an entity expansion bomb never reaches the parser" do
      bomb = ~s(<!DOCTYPE b [<!ENTITY a "aa"><!ENTITY b "&a;&a;">]><x>&b;</x>)

      assert {:error, {:xml, :dtd_forbidden}} = XML.parse(bomb)
    end

    test "accented Portuguese survives the parse (every SEFAZ rejection has it)" do
      body =
        ~s(<?xml version="1.0" encoding="utf-8"?><r><cStat>107</cStat>) <>
          ~s(<xMotivo>Servi\u00e7o em Opera\u00e7\u00e3o</xMotivo></r>)

      assert {:ok, doc} = XML.parse(body)
      assert XML.text(doc, "xMotivo") == "Serviço em Operação"
    end

    test "a real SP response parses, accents and all" do
      body =
        ~s(<?xml version="1.0" encoding="utf-8"?>) <>
          ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">) <>
          ~s(<soap:Body><nfeResultMsg xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeStatusServico4">) <>
          ~s(<retConsStatServ versao="4.00" xmlns="http://www.portalfiscal.inf.br/nfe">) <>
          ~s(<tpAmb>2</tpAmb><verAplic>SP_NFE_PL009_V4</verAplic><cStat>107</cStat>) <>
          ~s(<xMotivo>Servi\u00e7o em Opera\u00e7\u00e3o</xMotivo><cUF>35</cUF>) <>
          ~s(<tMed>1</tMed></retConsStatServ></nfeResultMsg></soap:Body></soap:Envelope>)

      assert {:ok, result} = Result.parse(body)
      assert result.c_stat == 107
      assert result.x_motivo == "Serviço em Operação"
    end

    test "namespace prefixes do not hide the elements" do
      assert {:ok, doc} = XML.parse(~s(<a:r xmlns:a="urn:x"><a:cStat>107</a:cStat></a:r>))
      assert XML.integer(doc, "cStat") == 107
    end
  end

  describe "connect_error/1" do
    alias SefazNfe.SOAP.HTTPC

    test "a TLS decode_error is tagged as the runtime limitation it is" do
      details = [
        {:to_address, {~c"nfe.svrs.rs.gov.br", 443}},
        {:inet, [:inet], {:tls_alert, {:decode_error, ~c"..."}}}
      ]

      assert {:tls, :decode_error, :otp_cert_auths_bug} = HTTPC.connect_error(details)
    end

    test "other TLS alerts keep their own name" do
      details = [{:inet, [:inet], {:tls_alert, {:unknown_ca, ~c"..."}}}]

      assert {:tls, :unknown_ca} = HTTPC.connect_error(details)
    end

    test "DNS and timeouts are told apart from unreachable" do
      assert {:dns, :nxdomain} = HTTPC.connect_error([{:inet, [:inet], :nxdomain}])
      assert :timeout = HTTPC.connect_error([{:inet, [:inet], :timeout}])
      assert :unreachable = HTTPC.connect_error([{:to_address, {~c"x", 443}}])
    end
  end

  test "mix test cannot open a socket: the configured client is the stub" do
    assert SefazNfe.SOAP.client() == SefazNfe.SOAP.NotImplemented
  end

  describe "isolated_call/4 timeout" do
    defmodule RecordsOpts do
      @moduledoc false
      @behaviour SefazNfe.SOAP

      @impl SefazNfe.SOAP
      def call(_endpoint, _body, _cert, opts) do
        send(:soap_timeout_test, {:opts, opts})
        {:ok, "<x/>"}
      end
    end

    setup do
      Process.register(self(), :soap_timeout_test)
      previous = Application.get_env(:sefaz_nfe, :soap)
      Application.put_env(:sefaz_nfe, :soap, RecordsOpts)
      on_exit(fn -> Application.put_env(:sefaz_nfe, :soap, previous) end)
    end

    # The option has to govern the request, not only the task supervising it.
    # Forwarded to the task alone it can shorten a call and never lengthen one,
    # which is the opposite of what a caller raising it wants.
    test "reaches the client, so it can raise the request deadline too" do
      SefazNfe.SOAP.isolated_call("https://example.test", "<x/>", SefazNfe.Fixtures.cert(),
        uf: "SP",
        timeout: to_timeout(second: 120)
      )

      assert_receive {:opts, opts}
      assert Keyword.get(opts, :timeout) == to_timeout(second: 120)
    end

    # Measured against SEFAZ-BA: `time_connect` ranged from 3.5 seconds to 68.7
    # across consecutive requests. Connecting is the part that hangs, so a task
    # window keyed on the request timeout alone would cut the connect short.
    test "a connect timeout past the request timeout is not cut short by the task" do
      SefazNfe.SOAP.isolated_call("https://example.test", "<x/>", SefazNfe.Fixtures.cert(),
        uf: "BA",
        timeout: to_timeout(second: 30),
        connect_timeout: to_timeout(second: 90)
      )

      assert_receive {:opts, opts}
      assert Keyword.get(opts, :connect_timeout) == to_timeout(second: 90)
    end

    test "the default reaches it as well, rather than being left to the client" do
      SefazNfe.SOAP.isolated_call("https://example.test", "<x/>", SefazNfe.Fixtures.cert(),
        uf: "MG"
      )

      assert_receive {:opts, opts}
      assert Keyword.get(opts, :timeout) == to_timeout(second: 30)
    end
  end
end
