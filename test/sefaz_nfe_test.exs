defmodule SefazNfeTest do
  use ExUnit.Case, async: true

  @cert SefazNfe.Fixtures.cert()

  @ch String.duplicate("1", 44)
  @cnpj "00000000000191"
  @cpf "00000000191"
  @nfe_ns "http://www.portalfiscal.inf.br/nfe"
  @id "NFe35260100000000000191550010000000011000000017"
  @body ~s(<total><ICMSTot><vICMS>10.00</vICMS></ICMSTot></total></infNFe></NFe>)

  @xml_homolog ~s(<NFe xmlns="#{@nfe_ns}"><infNFe Id="#{@id}" versao="4.00">) <>
                 ~s(<ide><tpAmb>2</tpAmb></ide>) <> @body

  @xml_prod ~s(<NFe xmlns="#{@nfe_ns}"><infNFe Id="#{@id}" versao="4.00">) <>
              ~s(<ide><tpAmb>1</tpAmb></ide>) <> @body

  test "certificate load rejects empty pfx or password" do
    assert {:error, :invalid_certificate} = SefazNfe.Certificate.load("", "x")
    assert {:error, :invalid_certificate} = SefazNfe.Certificate.load("x", "")
  end

  test "certificate inspect is redacted" do
    refute inspect(@cert) =~ "secret"
    refute inspect(@cert) =~ "pkcs12"
    assert inspect(@cert) =~ "redacted"
  end

  test "authorize signs, then reaches the transport" do
    assert {:error, :not_implemented} =
             SefazNfe.authorize(%{
               xml: @xml_homolog,
               cert: @cert,
               uf: "SP",
               environment: :homologation
             })
  end

  test "authorize refuses an infNFe with no Id, rather than signing nothing" do
    without_id = String.replace(@xml_homolog, ~s( Id="#{@id}"), "")

    assert {:error, {:signer, {:missing_id, "infNFe"}}} =
             SefazNfe.authorize(%{
               xml: without_id,
               cert: @cert,
               uf: "SP",
               environment: :homologation
             })
  end

  test "authorize refuses production XML in homologation" do
    assert {:error, :environment_mismatch} =
             SefazNfe.authorize(%{
               xml: @xml_prod,
               cert: @cert,
               uf: "SP",
               environment: :homologation
             })
  end

  test "authorize refuses AN" do
    assert {:error, {:unknown_endpoint, "AN", :nfe_autorizacao}} =
             SefazNfe.authorize(%{
               xml: @xml_homolog,
               cert: @cert,
               uf: "AN",
               environment: :homologation
             })
  end

  test "consult_protocol rejects short chave" do
    assert {:error, :invalid_ch_nfe} =
             SefazNfe.consult_protocol(%{
               ch_nfe: "123",
               cert: @cert,
               uf: "SP",
               environment: :homologation
             })
  end

  test "consult_protocol 44-digit chave reaches not_implemented" do
    assert {:error, :not_implemented} =
             SefazNfe.consult_protocol(%{
               ch_nfe: @ch,
               cert: @cert,
               uf: "SP",
               environment: :homologation
             })
  end

  test "cancel rejects short justification" do
    assert {:error, :justification_too_short} =
             SefazNfe.cancel(%{
               ch_nfe: @ch,
               n_prot: "1",
               justification: "curto",
               cert: @cert,
               uf: "SP",
               environment: :homologation
             })
  end

  test "dist_dfe requires the interested party tax_id" do
    assert {:error, {:missing_keys, [:tax_id]}} =
             SefazNfe.dist_dfe(%{cert: @cert, environment: :homologation, ult_nsu: "0"})
  end

  test "dist_dfe requires a query cursor" do
    assert {:error, {:missing_keys, [:ult_nsu]}} =
             SefazNfe.dist_dfe(%{tax_id: @cnpj, cert: @cert, environment: :homologation})
  end

  test "dist_dfe with ult_nsu reaches not_implemented" do
    assert {:error, :not_implemented} =
             SefazNfe.dist_dfe(%{
               tax_id: @cnpj,
               cert: @cert,
               environment: :production,
               ult_nsu: "0"
             })
  end

  test "dist_dfe accepts a CPF and the alphanumeric CNPJ (NT 2025.002)" do
    for id <- [@cpf, @cnpj, "12ABC34501DE35"] do
      assert {:error, :not_implemented} =
               SefazNfe.dist_dfe(%{
                 tax_id: id,
                 cert: @cert,
                 environment: :production,
                 ult_nsu: "0"
               })
    end
  end

  test "dist_dfe rejects a malformed tax_id before SOAP" do
    for id <- ["123", "0000000000019", "0000000000019X", "12abc34501de35", :not_a_binary] do
      assert {:error, :invalid_tax_id} =
               SefazNfe.dist_dfe(%{
                 tax_id: id,
                 cert: @cert,
                 environment: :production,
                 ult_nsu: "0"
               })
    end
  end

  test "service_status missing keys" do
    assert {:error, {:missing_keys, [:cert, :uf, :environment]}} = SefazNfe.service_status(%{})
  end

  test "an already signed XML is passed through, not signed again" do
    signed = "<NFe><infNFe/><Signature xmlns=\"http://www.w3.org/2000/09/xmldsig#\"/></NFe>"

    assert SefazNfe.Signer.signed?(signed)
    assert {:ok, ^signed} = SefazNfe.Signer.sign_nfe(signed, @cert)

    refute SefazNfe.Signer.signed?(@xml_homolog)
    assert {:ok, output} = SefazNfe.Signer.sign_nfe(@xml_homolog, @cert)
    assert SefazNfe.Signer.signed?(output)
  end

  test "SOAP emits telemetry without leaking cert or body (SEFAZ-14)" do
    handler = {__MODULE__, :telemetry_handler}

    :telemetry.attach(handler, [:sefaz_nfe, :soap, :stop], &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    SefazNfe.SOAP.isolated_call("https://example.test", "<nfe/>", @cert,
      uf: "SP",
      service: :nfe_status_servico
    )

    assert_receive {:telemetry, measurements, metadata}
    assert is_integer(measurements.duration)
    assert metadata.uf == "SP"
    assert metadata.service == :nfe_status_servico
    assert metadata.outcome == :not_implemented

    refute Map.has_key?(metadata, :cert)
    refute Map.has_key?(metadata, :body)
    refute inspect(metadata) =~ "pkcs12"
  end

  def forward(_event, measurements, metadata, test) do
    send(test, {:telemetry, measurements, metadata})
  end

  test "the configured test client is the offline stub" do
    assert {:error, :not_implemented} =
             SefazNfe.SOAP.client().call("https://example", "<x/>", @cert, [])
  end
end
