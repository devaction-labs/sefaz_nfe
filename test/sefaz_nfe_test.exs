defmodule SefazNfeTest do
  use ExUnit.Case, async: true

  @cert elem(SefazNfe.Certificate.load(<<"pkcs12-placeholder">>, "secret"), 1)

  @ch String.duplicate("1", 44)
  @xml_homolog "<NFe><infNFe><ide><tpAmb>2</tpAmb></ide></infNFe></NFe>"
  @xml_prod "<NFe><infNFe><ide><tpAmb>1</tpAmb></ide></infNFe></NFe>"

  test "certificate load rejects empty pfx or password" do
    assert {:error, :invalid_certificate} = SefazNfe.Certificate.load("", "x")
    assert {:error, :invalid_certificate} = SefazNfe.Certificate.load("x", "")
  end

  test "certificate inspect is redacted" do
    refute inspect(@cert) =~ "secret"
    refute inspect(@cert) =~ "pkcs12"
    assert inspect(@cert) =~ "redacted"
  end

  test "authorize resolves SP homolog then not_implemented" do
    assert {:error, :not_implemented} =
             SefazNfe.authorize(%{
               xml: @xml_homolog,
               cert: @cert,
               uf: "SP",
               ambiente: :homologacao
             })
  end

  test "authorize refuses producao XML in homologacao" do
    assert {:error, :ambiente_mismatch} =
             SefazNfe.authorize(%{
               xml: @xml_prod,
               cert: @cert,
               uf: "SP",
               ambiente: :homologacao
             })
  end

  test "authorize refuses AN" do
    assert {:error, {:unknown_endpoint, "AN", :nfe_autorizacao}} =
             SefazNfe.authorize(%{
               xml: @xml_homolog,
               cert: @cert,
               uf: "AN",
               ambiente: :homologacao
             })
  end

  test "consulta_protocolo rejects short chave" do
    assert {:error, :invalid_ch_nfe} =
             SefazNfe.consulta_protocolo(%{
               ch_nfe: "123",
               cert: @cert,
               uf: "SP",
               ambiente: :homologacao
             })
  end

  test "consulta_protocolo 44-digit chave reaches not_implemented" do
    assert {:error, :not_implemented} =
             SefazNfe.consulta_protocolo(%{
               ch_nfe: @ch,
               cert: @cert,
               uf: "SP",
               ambiente: :homologacao
             })
  end

  test "cancela rejects short justificativa" do
    assert {:error, :justificativa_curta} =
             SefazNfe.cancela(%{
               ch_nfe: @ch,
               n_prot: "1",
               justificativa: "curto",
               cert: @cert,
               uf: "SP",
               ambiente: :homologacao
             })
  end

  test "dist_dfe requires a query cursor" do
    assert {:error, {:missing_keys, [:ult_nsu]}} =
             SefazNfe.dist_dfe(%{cert: @cert, ambiente: :homologacao})
  end

  test "dist_dfe with ult_nsu reaches not_implemented" do
    assert {:error, :not_implemented} =
             SefazNfe.dist_dfe(%{cert: @cert, ambiente: :producao, ult_nsu: "0"})
  end

  test "status_servico missing keys" do
    assert {:error, {:missing_keys, [:cert, :uf, :ambiente]}} = SefazNfe.status_servico(%{})
  end

  test "SOAP default client is NotImplemented" do
    assert {:error, :not_implemented} =
             SefazNfe.SOAP.client().call("https://example", "<x/>", @cert, [])
  end
end
