defmodule SefazNfe.TaxpayerTest do
  use ExUnit.Case, async: true

  alias SefazNfe.Endpoints
  alias SefazNfe.SOAP.Envelope
  alias SefazNfe.Taxpayer
  alias SefazNfe.TaxpayerLookup

  @wsdl "http://www.portalfiscal.inf.br/nfe/wsdl/CadConsultaCadastro4"

  describe "envelope" do
    test "filter by CNPJ, CPF or IE" do
      assert Envelope.consult_taxpayer("BA", {:tax_id, "12345678000195"}) ==
               ~s(<ConsCad xmlns="http://www.portalfiscal.inf.br/nfe" versao="2.00">) <>
                 ~s(<infCons><xServ>CONS-CAD</xServ><UF>BA</UF><CNPJ>12345678000195</CNPJ>) <>
                 ~s(</infCons></ConsCad>)

      assert Envelope.consult_taxpayer("SP", {:tax_id, "12345678901"}) =~ "<CPF>12345678901</CPF>"
      assert Envelope.consult_taxpayer("SP", {:ie, "110042490114"}) =~ "<IE>110042490114</IE>"
    end

    test "MT nests the message in an extra nfeDadosMsg without namespace" do
      message = Envelope.consult_taxpayer("MT", {:ie, "131234567"})

      assert String.starts_with?(message, "<nfeDadosMsg><ConsCad ")
      assert String.ends_with?(message, "</ConsCad></nfeDadosMsg>")

      assert {:ok, envelope} = Envelope.wrap(:nfe_consulta_cadastro, message)
      assert envelope =~ ~s(<nfeDadosMsg xmlns="#{@wsdl}"><nfeDadosMsg><ConsCad)
    end

    test "other UFs are not nested" do
      refute Envelope.consult_taxpayer("MG", {:ie, "131234567"}) =~ "nfeDadosMsg"
    end

    test "wraps in the CadConsultaCadastro4 namespace" do
      assert {:ok, envelope} = Envelope.wrap(:nfe_consulta_cadastro, "<ConsCad/>")
      assert envelope =~ ~s(<nfeDadosMsg xmlns="#{@wsdl}"><ConsCad/></nfeDadosMsg>)
    end

    test "the action follows the authorizer's operation" do
      assert {:ok, "#{@wsdl}/consultaCadastro"} ==
               Envelope.action(
                 :nfe_consulta_cadastro,
                 Endpoints.operation("BA", :nfe_consulta_cadastro)
               )

      assert {:ok, "#{@wsdl}/consultaCadastro4"} ==
               Envelope.action(
                 :nfe_consulta_cadastro,
                 Endpoints.operation("SC", :nfe_consulta_cadastro)
               )

      assert {:ok, "#{@wsdl}/consultaCadastro4"} == Envelope.action(:nfe_consulta_cadastro)
    end

    test "other services keep their fixed operation" do
      assert {:ok, "http://www.portalfiscal.inf.br/nfe/wsdl/NFeStatusServico4/nfeStatusServicoNF"} ==
               Envelope.action(:nfe_status_servico)

      assert Endpoints.operation("BA", :nfe_status_servico) == nil
    end
  end

  describe "endpoints" do
    test "BA, a SVRS state, MG" do
      assert {:ok, ba} = Endpoints.url("BA", :homologation, :nfe_consulta_cadastro)

      assert ba ==
               "https://hnfe.sefaz.ba.gov.br/webservices/CadConsultaCadastro4/CadConsultaCadastro4.asmx"

      assert {:ok, sc} = Endpoints.url("SC", :production, :nfe_consulta_cadastro)
      assert sc == "https://cad.svrs.rs.gov.br/ws/cadconsultacadastro/cadconsultacadastro4.asmx"

      assert {:ok, "https://nfe.fazenda.mg.gov.br/nfe2/services/CadConsultaCadastro4"} =
               Endpoints.url("MG", :production, :nfe_consulta_cadastro)
    end

    test "operation per authorizer is data" do
      for uf <- ~w(BA GO MS MT SP),
          do: assert(Endpoints.operation(uf, :nfe_consulta_cadastro) == "consultaCadastro")

      for uf <- ~w(MG PE PR RS SC RJ),
          do: assert(Endpoints.operation(uf, :nfe_consulta_cadastro) == "consultaCadastro4")
    end

    test "AM and MA (SVAN) do not offer the service" do
      assert {:error, {:unknown_endpoint, "AM", :nfe_consulta_cadastro}} =
               Endpoints.url("AM", :production, :nfe_consulta_cadastro)

      assert {:error, {:unknown_endpoint, "MA", :nfe_consulta_cadastro}} =
               Endpoints.url("MA", :homologation, :nfe_consulta_cadastro)
    end
  end

  describe "validation" do
    defp opts(extra) do
      Map.merge(
        %{cert: SefazNfe.Fixtures.cert(), uf: "BA", environment: :homologation},
        Map.new(extra)
      )
    end

    test "neither filter" do
      assert {:error, {:invalid_filter, :missing}} = SefazNfe.consult_taxpayer(opts([]))
    end

    test "both filters" do
      assert {:error, {:invalid_filter, :ambiguous}} =
               SefazNfe.consult_taxpayer(opts(tax_id: "12345678000195", ie: "123456789"))
    end

    test "bad tax id and bad IE" do
      assert {:error, :invalid_tax_id} = SefazNfe.consult_taxpayer(opts(tax_id: "123"))
      assert {:error, :invalid_ie} = SefazNfe.consult_taxpayer(opts(ie: "1"))
      assert {:error, :invalid_ie} = SefazNfe.consult_taxpayer(opts(ie: "12.345.678"))
      assert {:error, :invalid_ie} = SefazNfe.consult_taxpayer(opts(ie: "123456789012345"))
    end

    test "missing keys and environment" do
      assert {:error, {:missing_keys, [:uf]}} =
               SefazNfe.consult_taxpayer(%{
                 cert: SefazNfe.Fixtures.cert(),
                 environment: :production
               })

      assert {:error, :invalid_environment} =
               SefazNfe.consult_taxpayer(opts(environment: :staging, ie: "123456789"))
    end
  end

  describe "parse" do
    defp response(inf_cons) do
      ~s(<?xml version="1.0" encoding="utf-8"?>) <>
        ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
        ~s(<nfeResultMsg xmlns="#{@wsdl}">) <>
        ~s(<retConsCad xmlns="http://www.portalfiscal.inf.br/nfe" versao="2.00">) <>
        ~s(<infCons>#{inf_cons}</infCons></retConsCad></nfeResultMsg></soap:Body></soap:Envelope>)
    end

    defp inf_cad(ie, name) do
      ~s(<infCad><IE>#{ie}</IE><CNPJ>12345678000195</CNPJ><UF>BA</UF><cSit>1</cSit>) <>
        ~s(<indCredNFe>1</indCredNFe><indCredCTe>4</indCredCTe><xNome>#{name}</xNome>) <>
        ~s(<xFant>Fantasia</xFant><xRegApur>NORMAL</xRegApur><CNAE>4644301</CNAE>) <>
        ~s(<dIniAtiv>2010-03-01</dIniAtiv><dUltSit>2010-03-01</dUltSit><dBaixa></dBaixa>) <>
        ~s(<IEUnica>#{ie}</IEUnica><IEAtual>#{ie}</IEAtual>) <>
        ~s(<ender><xLgr>RUA A</xLgr><nro>10</nro><xCpl>SALA 2</xCpl><xBairro>CENTRO</xBairro>) <>
        ~s(<cMun>2927408</cMun><xMun>SALVADOR</xMun><CEP>40000000</CEP></ender></infCad>)
    end

    test "111: one record with its address" do
      body =
        response(
          ~s(<verAplic>BA_CAD_1</verAplic><cStat>111</cStat><xMotivo>Consulta cadastro com uma ocorrencia</xMotivo>) <>
            ~s(<UF>BA</UF><CNPJ>12345678000195</CNPJ><dhCons>2026-11-22T10:00:00-03:00</dhCons><cUF>29</cUF>) <>
            inf_cad("0123456", "EMPRESA UM LTDA")
        )

      assert {:ok, %TaxpayerLookup{} = lookup} = TaxpayerLookup.parse(body)
      assert lookup.c_stat == 111
      assert lookup.x_motivo == "Consulta cadastro com uma ocorrencia"
      assert lookup.uf == "BA"
      assert lookup.dh_cons == "2026-11-22T10:00:00-03:00"

      assert [%Taxpayer{} = taxpayer] = lookup.taxpayers
      assert taxpayer.ie == "0123456"
      assert taxpayer.cnpj == "12345678000195"
      assert taxpayer.cpf == nil
      assert taxpayer.uf == "BA"
      assert taxpayer.c_sit == 1
      assert taxpayer.ind_cred_nfe == 1
      assert taxpayer.ind_cred_cte == 4
      assert taxpayer.x_nome == "EMPRESA UM LTDA"
      assert taxpayer.x_fant == "Fantasia"
      assert taxpayer.x_reg_apur == "NORMAL"
      assert taxpayer.cnae == "4644301"
      assert taxpayer.d_ini_ativ == "2010-03-01"
      assert taxpayer.d_ult_sit == "2010-03-01"
      assert taxpayer.d_baixa == nil
      assert taxpayer.ie_unica == "0123456"
      assert taxpayer.ie_atual == "0123456"

      assert taxpayer.address == %{
               x_lgr: "RUA A",
               nro: "10",
               x_cpl: "SALA 2",
               x_bairro: "CENTRO",
               c_mun: "2927408",
               x_mun: "SALVADOR",
               cep: "40000000"
             }
    end

    test "112: several records" do
      body =
        response(
          ~s(<verAplic>BA_CAD_1</verAplic><cStat>112</cStat><xMotivo>Consulta cadastro com mais de uma ocorrencia</xMotivo>) <>
            ~s(<UF>BA</UF><CNPJ>12345678000195</CNPJ><dhCons>2026-11-22T10:00:00-03:00</dhCons><cUF>29</cUF>) <>
            inf_cad("0123456", "MATRIZ") <> inf_cad("0654321", "FILIAL")
        )

      assert {:ok, lookup} = TaxpayerLookup.parse(body)
      assert lookup.c_stat == 112
      assert Enum.map(lookup.taxpayers, & &1.ie) == ["0123456", "0654321"]
      assert Enum.map(lookup.taxpayers, & &1.x_nome) == ["MATRIZ", "FILIAL"]
    end

    test "259: a rejection is a business outcome with no taxpayers" do
      body =
        response(
          ~s(<verAplic>BA_CAD_1</verAplic><cStat>259</cStat>) <>
            ~s(<xMotivo>Rejeicao: CNPJ da consulta nao cadastrado como contribuinte na UF</xMotivo>) <>
            ~s(<UF>BA</UF><CNPJ>12345678000195</CNPJ><dhCons>2026-11-22T10:00:00-03:00</dhCons><cUF>29</cUF>)
        )

      assert {:ok, %TaxpayerLookup{c_stat: 259, taxpayers: []} = lookup} =
               TaxpayerLookup.parse(body)

      assert lookup.x_motivo =~ "nao cadastrado"
    end

    test "a SOAP fault and an unreadable body are errors" do
      fault =
        ~s(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) <>
          ~s(<soap:Fault><soap:Reason><soap:Text>boom</soap:Text></soap:Reason></soap:Fault>) <>
          ~s(</soap:Body></soap:Envelope>)

      assert {:error, {:soap_fault, "boom"}} = TaxpayerLookup.parse(fault)
      assert {:error, {:xml, :malformed}} = TaxpayerLookup.parse("<<<")
      assert {:error, {:xml, :no_c_stat}} = TaxpayerLookup.parse("<a/>")
    end
  end
end
