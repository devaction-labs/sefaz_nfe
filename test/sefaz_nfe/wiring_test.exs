defmodule SefazNfe.WiringTest do
  @moduledoc """
  End-to-end wiring of a public function: envelope, transport, parse.

  `async: false` because swapping `:sefaz_nfe, :soap` mutates application
  environment that every other test reads. ExUnit finishes the whole async
  suite before any sync case, so the swap cannot race with it.
  """

  use ExUnit.Case, async: false

  alias SefazNfe.SOAP.Envelope

  defmodule StatusStub do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(endpoint, body, _cert, _opts) do
      send(:sefaz_nfe_wiring_test, {:posted, endpoint, body})

      {:ok,
       ~s(<?xml version="1.0" encoding="utf-8"?>) <>
         ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
         ~s(<nfeResultMsg xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeStatusServico4">) <>
         ~s(<retConsStatServ versao="4.00" xmlns="http://www.portalfiscal.inf.br/nfe">) <>
         ~s(<tpAmb>2</tpAmb><verAplic>SP_NFE_PL009_V4</verAplic><cStat>107</cStat>) <>
         ~s(<xMotivo>Serviço em Operação</xMotivo><cUF>35</cUF><tMed>1</tMed>) <>
         ~s(</retConsStatServ></nfeResultMsg></soap:Body></soap:Envelope>)}
    end
  end

  setup do
    previous = Application.get_env(:sefaz_nfe, :soap)
    Process.register(self(), :sefaz_nfe_wiring_test)
    Application.put_env(:sefaz_nfe, :soap, StatusStub)

    on_exit(fn -> Application.put_env(:sefaz_nfe, :soap, previous) end)
    :ok
  end

  test "service_status builds the envelope, posts it and parses the answer" do
    assert {:ok, result} =
             SefazNfe.service_status(%{
               cert: SefazNfe.Fixtures.cert(),
               uf: "SP",
               environment: :homologation
             })

    assert result.c_stat == 107
    assert result.x_motivo == "Serviço em Operação"

    assert_receive {:posted, url, envelope}
    assert url == "https://homologacao.nfe.fazenda.sp.gov.br/ws/nfestatusservico4.asmx"
    assert envelope =~ ~s(xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeStatusServico4")
    assert envelope =~ "<cUF>35</cUF>"
    assert envelope =~ "<tpAmb>2</tpAmb>"
    assert envelope =~ "<xServ>STATUS</xServ>"
  end

  defmodule CadastroStub do
    @moduledoc false
    @behaviour SefazNfe.SOAP

    @impl SefazNfe.SOAP
    def call(endpoint, body, _cert, opts) do
      send(:sefaz_nfe_wiring_test, {:posted, endpoint, body, opts})

      {:ok,
       ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
         ~s(<retConsCad xmlns="http://www.portalfiscal.inf.br/nfe" versao="2.00"><infCons>) <>
         ~s(<cStat>111</cStat><xMotivo>Consulta cadastro com uma ocorrencia</xMotivo>) <>
         ~s(<UF>BA</UF><dhCons>2026-11-22T10:00:00-03:00</dhCons>) <>
         ~s(<infCad><IE>0123456</IE><CNPJ>12345678000195</CNPJ><cSit>1</cSit></infCad>) <>
         ~s(</infCons></retConsCad></soap:Body></soap:Envelope>)}
    end
  end

  test "consult_taxpayer posts to the authorizer with its own operation and parses the answer" do
    Application.put_env(:sefaz_nfe, :soap, CadastroStub)

    assert {:ok, lookup} =
             SefazNfe.consult_taxpayer(%{
               cert: SefazNfe.Fixtures.cert(),
               uf: "BA",
               environment: :homologation,
               tax_id: "12345678000195"
             })

    assert lookup.c_stat == 111
    assert [%SefazNfe.Taxpayer{ie: "0123456", c_sit: 1}] = lookup.taxpayers

    assert_receive {:posted, url, envelope, opts}
    assert url =~ "hnfe.sefaz.ba.gov.br/webservices/CadConsultaCadastro4"
    assert envelope =~ ~s(xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/CadConsultaCadastro4")
    assert envelope =~ "<xServ>CONS-CAD</xServ><UF>BA</UF><CNPJ>12345678000195</CNPJ>"
    assert opts[:service] == :nfe_consulta_cadastro
    assert opts[:operation] == "consultaCadastro"

    assert {:ok, "http://www.portalfiscal.inf.br/nfe/wsdl/CadConsultaCadastro4/consultaCadastro"} =
             Envelope.action(opts[:service], opts[:operation])
  end

  test "consult_taxpayer on an authorizer without the service never reaches the transport" do
    Application.put_env(:sefaz_nfe, :soap, CadastroStub)

    assert {:error, {:unknown_endpoint, "AM", :nfe_consulta_cadastro}} =
             SefazNfe.consult_taxpayer(%{
               cert: SefazNfe.Fixtures.cert(),
               uf: "AM",
               environment: :production,
               ie: "123456789"
             })

    refute_receive {:posted, _url, _envelope, _opts}
  end

  test "an unknown UF never reaches the transport" do
    assert {:error, {:unknown_endpoint, "XX", :nfe_status_servico}} =
             SefazNfe.service_status(%{
               cert: SefazNfe.Fixtures.cert(),
               uf: "XX",
               environment: :homologation
             })

    refute_receive {:posted, _url, _envelope}
  end
end
