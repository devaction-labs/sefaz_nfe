defmodule SefazNfe.WiringTest do
  @moduledoc """
  End-to-end wiring of a public function: envelope, transport, parse.

  `async: false` because swapping `:sefaz_nfe, :soap` mutates application
  environment that every other test reads. ExUnit finishes the whole async
  suite before any sync case, so the swap cannot race with it.
  """

  use ExUnit.Case, async: false

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
