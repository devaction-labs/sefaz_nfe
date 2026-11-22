defmodule SefazNfe.CTeMDFeEndpointsTest do
  @moduledoc """
  CT-e (57, 67) and MDF-e (58) routing by model, the SOAP action strings and the
  status messages. The status messages are checked against the XSDs when
  `SEFAZ_NFE_CTE_PL_PATH` and `SEFAZ_NFE_MDFE_PL_PATH` point at the PL
  directories (they are not vendored, AD-015) and `xmllint` exists.
  """

  use ExUnit.Case, async: true

  alias SefazNfe.Endpoints
  alias SefazNfe.SOAP.Envelope

  @cte_pl System.get_env("SEFAZ_NFE_CTE_PL_PATH")
  @have_cte_pl is_binary(@cte_pl) and
                 File.exists?(Path.join(@cte_pl, "consStatServCTe_v4.00.xsd")) and
                 System.find_executable("xmllint") != nil

  @mdfe_pl System.get_env("SEFAZ_NFE_MDFE_PL_PATH")
  @have_mdfe_pl is_binary(@mdfe_pl) and
                  File.exists?(Path.join(@mdfe_pl, "consStatServMDFe_v3.00.xsd")) and
                  System.find_executable("xmllint") != nil

  @ufs ~w(AC AL AM AP BA CE DF ES GO MA MG MS MT PA PB PE PI PR RJ RN RO RR RS SC SE SP TO)
  @cte_services ~w(cte_recepcao_sinc cte_recepcao_os cte_consulta cte_status_servico
                   cte_recepcao_evento)a
  @mdfe_services ~w(mdfe_recepcao_sinc mdfe_consulta mdfe_status_servico mdfe_recepcao_evento
                    mdfe_consulta_nao_enc)a

  describe "CT-e resolution (the authorizer is per model, not per UF)" do
    test "BA is SVRS for CT-e while it authorizes NF-e itself" do
      assert {:ok, "https://cte.svrs.rs.gov.br/ws/CTeStatusServicoV4/CTeStatusServicoV4.asmx"} =
               Endpoints.url("BA", :production, :cte_status_servico, 57)

      assert {:ok, "https://nfe.sefaz.ba.gov.br" <> _} =
               Endpoints.url("BA", :production, :nfe_status_servico, 55)
    end

    test "PE is SVSP for CT-e while it authorizes NF-e itself" do
      assert {:ok, "https://nfe.fazenda.sp.gov.br/CTeWS/WS/CTeStatusServicoV4.asmx"} =
               Endpoints.url("PE", :production, :cte_status_servico, 57)

      assert {:ok, "https://nfe.sefaz.pe.gov.br" <> _} =
               Endpoints.url("PE", :production, :nfe_status_servico, 55)
    end

    test "SP runs its own authorizer, in both environments" do
      assert {:ok, "https://homologacao.nfe.fazenda.sp.gov.br/CTeWS/WS/CTeRecepcaoSincV4.asmx"} =
               Endpoints.url("SP", :homologation, :cte_recepcao_sinc, 57)

      assert {:ok, "https://nfe.fazenda.sp.gov.br/CTeWS/WS/CTeConsultaV4.asmx"} =
               Endpoints.url(:sp, :production, :cte_consulta, 57)
    end

    test "the snapshot keeps the bare service URL, without ?wsdl" do
      assert {:ok, "https://cte.sefaz.mt.gov.br/ctews2/services/CTeRecepcaoEventoV4"} =
               Endpoints.url("MT", :production, :cte_recepcao_evento, 57)
    end

    test "model 67 resolves through the CT-e table and sends through CT-e OS" do
      assert {:ok, "https://cte.svrs.rs.gov.br/ws/CTeRecepcaoOSV4/CTeRecepcaoOSV4.asmx"} =
               Endpoints.url("BA", :production, :cte_recepcao_os, 67)

      assert {:ok, "https://homologacao.cte.ms.gov.br/ws/CTeRecepcaoOSV4"} =
               Endpoints.url("MS", :homologation, :cte_recepcao_os, 67)

      for uf <- @ufs, environment <- [:homologation, :production], service <- @cte_services do
        assert Endpoints.url(uf, environment, service, 67) ==
                 Endpoints.url(uf, environment, service, 57)
      end
    end

    test "every UF resolves every CT-e service in both environments, over https .gov.br" do
      for uf <- @ufs, environment <- [:homologation, :production], service <- @cte_services do
        assert {:ok, url} = Endpoints.url(uf, environment, service, 57), "#{uf} #{service}"
        uri = URI.parse(url)
        assert uri.scheme == "https"
        assert String.ends_with?(uri.host, ".gov.br")
        refute url =~ "?wsdl"
      end
    end

    test "the authorizers are the six own ones plus SVRS and SVSP" do
      snapshot = JSON.decode!(File.read!("priv/endpoints/cte_4.00.json"))

      assert snapshot["authorizers"] |> Map.keys() |> Enum.sort() ==
               ~w(MG MS MT PR RS SP SVRS SVSP)

      assert for({uf, "SVSP"} <- snapshot["uf_authorizer"], do: uf) |> Enum.sort() ==
               ~w(AP PE RR)

      own = for {uf, authorizer} <- snapshot["uf_authorizer"], uf == authorizer, do: uf
      assert Enum.sort(own) == ~w(MG MS MT PR RS SP)
      assert map_size(snapshot["uf_authorizer"]) == 27
    end

    test "services of another model are not CT-e services" do
      assert {:error, {:unknown_service, :nfe_status_servico}} =
               Endpoints.url("SP", :production, :nfe_status_servico, 57)

      assert {:error, {:unknown_service, :cte_status_servico}} =
               Endpoints.url("SP", :production, :cte_status_servico, 55)

      assert {:error, {:unknown_service, :mdfe_status_servico}} =
               Endpoints.url("SP", :production, :mdfe_status_servico, 57)
    end

    test "an unknown UF is reported, not silently routed" do
      assert {:error, {:unknown_endpoint, "XX", :cte_consulta}} =
               Endpoints.url("XX", :production, :cte_consulta, 57)
    end
  end

  describe "MDF-e resolution" do
    test "SVRS serves every UF" do
      assert {:ok, "https://mdfe.svrs.rs.gov.br/ws/MDFeStatusServico/MDFeStatusServico.asmx"} =
               Endpoints.url("BA", :production, :mdfe_status_servico, 58)

      assert {:ok,
              "https://mdfe-homologacao.svrs.rs.gov.br/ws/MDFeConsNaoEnc/MDFeConsNaoEnc.asmx"} =
               Endpoints.url("SP", :homologation, :mdfe_consulta_nao_enc, 58)

      for uf <- @ufs, environment <- [:homologation, :production], service <- @mdfe_services do
        assert {:ok, url} = Endpoints.url(uf, environment, service, 58), "#{uf} #{service}"
        assert url =~ "svrs.rs.gov.br"
      end
    end

    test "NF-e and CT-e services are not MDF-e services" do
      assert {:error, {:unknown_service, :cte_status_servico}} =
               Endpoints.url("BA", :production, :cte_status_servico, 58)
    end
  end

  describe "NF-e and NFC-e are unchanged" do
    test "the default model is still 55 and 65 still has its own table" do
      assert Endpoints.url("BA", :homologation, :nfe_autorizacao) ==
               Endpoints.url("BA", :homologation, :nfe_autorizacao, 55)

      assert {:ok, "https://nfce.svrs.rs.gov.br" <> _} =
               Endpoints.url("BA", :production, :nfe_autorizacao, 65)
    end

    test "an unsupported model is still named" do
      assert {:error, {:unsupported_model, 99}} =
               Endpoints.url("SP", :production, :nfe_autorizacao, 99)

      assert {:error, {:unsupported_model, 56}} =
               Endpoints.url("SP", :production, :cte_consulta, 56)
    end

    test "NF-e contingency is untouched" do
      assert {:ok, :svc_an} = Endpoints.contingency_for(:sp)
      assert {:ok, :svc_rs} = Endpoints.contingency_for("BA", 55)

      assert {:ok, "https://www.sefazvirtual.fazenda.gov.br" <> _} =
               Endpoints.contingency_url(:svc_an, :production, :nfe_autorizacao)

      assert {:error, {:invalid_contingency, :svc_sp}} =
               Endpoints.contingency_url(:svc_sp, :production, :nfe_autorizacao)
    end
  end

  describe "CT-e contingency (SVC-SP and SVC-RS, never SVC-AN)" do
    test "SVC-SP serves the UFs authorized by SVRS, MG, PR and RS" do
      for uf <- ~w(AC AL AM BA CE DF ES GO MA PA PB PI RJ RN RO SC SE TO MG PR RS) do
        assert {:ok, :svc_sp} = Endpoints.contingency_for(uf, 57), uf
        assert {:ok, :svc_sp} = Endpoints.contingency_for(uf, 67), uf
      end
    end

    test "SVC-RS serves the UFs authorized by SVSP, MT, MS and SP" do
      for uf <- ~w(AP PE RR MT MS SP) do
        assert {:ok, :svc_rs} = Endpoints.contingency_for(uf, 57), uf
      end
    end

    test "every UF has one" do
      for uf <- @ufs, model <- [57, 67] do
        assert {:ok, svc} = Endpoints.contingency_for(uf, model)
        assert svc in [:svc_sp, :svc_rs]
      end

      assert {:error, {:unknown_uf, "XX"}} = Endpoints.contingency_for("XX", 57)
    end

    test "NFC-e and MDF-e have no SVC" do
      assert {:error, {:unsupported_for_model, 65}} = Endpoints.contingency_for("SP", 65)
      assert {:error, {:unsupported_for_model, 58}} = Endpoints.contingency_for("SP", 58)
      assert {:error, {:unsupported_model, 99}} = Endpoints.contingency_for("SP", 99)
    end

    test "SVC-SP is served from the SVSP endpoints and SVC-RS from the SVRS ones" do
      assert {:ok, url} = Endpoints.contingency_url(:svc_sp, :production, :cte_recepcao_sinc, 57)
      assert url == "https://nfe.fazenda.sp.gov.br/CTeWS/WS/CTeRecepcaoSincV4.asmx"
      assert {:ok, ^url} = Endpoints.url("PE", :production, :cte_recepcao_sinc, 57)

      assert {:ok, url} = Endpoints.contingency_url(:svc_rs, :homologation, :cte_consulta, 67)
      assert {:ok, ^url} = Endpoints.url("BA", :homologation, :cte_consulta, 67)
    end

    test "an SVC that is not a CT-e one is refused" do
      assert {:error, {:invalid_contingency, :svc_an}} =
               Endpoints.contingency_url(:svc_an, :production, :cte_consulta, 57)

      assert {:error, {:unsupported_for_model, 58}} =
               Endpoints.contingency_url(:svc_rs, :production, :mdfe_consulta, 58)

      assert {:error, {:invalid_environment, :prod}} =
               Endpoints.contingency_url(:svc_sp, :prod, :cte_consulta, 57)

      assert {:error, {:unknown_service, :nfe_autorizacao}} =
               Endpoints.contingency_url(:svc_sp, :production, :nfe_autorizacao, 57)
    end
  end

  describe "the SOAP action" do
    test "CT-e actions follow NFePHP's namespace and method" do
      assert {:ok, "http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoSincV4/cteRecepcao"} =
               Envelope.action(:cte_recepcao_sinc)

      assert {:ok, "http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoOSV4/cteRecepcaoOS"} =
               Envelope.action(:cte_recepcao_os)

      assert {:ok, "http://www.portalfiscal.inf.br/cte/wsdl/CTeConsultaV4/cteConsultaCT"} =
               Envelope.action(:cte_consulta)

      assert {:ok,
              "http://www.portalfiscal.inf.br/cte/wsdl/CTeStatusServicoV4/cteStatusServicoCT"} =
               Envelope.action(:cte_status_servico)

      assert {:ok,
              "http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoEventoV4/cteRecepcaoEvento"} =
               Envelope.action(:cte_recepcao_evento)
    end

    test "MDF-e actions" do
      assert {:ok, "http://www.portalfiscal.inf.br/mdfe/wsdl/MDFeRecepcaoSinc/mdfeRecepcao"} =
               Envelope.action(:mdfe_recepcao_sinc)

      assert {:ok, "http://www.portalfiscal.inf.br/mdfe/wsdl/MDFeConsulta/mdfeConsultaMDF"} =
               Envelope.action(:mdfe_consulta)

      assert {:ok,
              "http://www.portalfiscal.inf.br/mdfe/wsdl/MDFeStatusServico/mdfeStatusServicoMDF"} =
               Envelope.action(:mdfe_status_servico)

      assert {:ok,
              "http://www.portalfiscal.inf.br/mdfe/wsdl/MDFeRecepcaoEvento/mdfeRecepcaoEvento"} =
               Envelope.action(:mdfe_recepcao_evento)

      assert {:ok, "http://www.portalfiscal.inf.br/mdfe/wsdl/MDFeConsNaoEnc/mdfeConsNaoEnc"} =
               Envelope.action(:mdfe_consulta_nao_enc)
    end

    test "NF-e actions are unchanged" do
      assert {:ok, "http://www.portalfiscal.inf.br/nfe/wsdl/NFeStatusServico4/nfeStatusServicoNF"} =
               Envelope.action(:nfe_status_servico)
    end

    test "the operation is data only where authorizers disagree, which CT-e and MDF-e do not" do
      for uf <- ["BA", "SP"], service <- @cte_services do
        assert Endpoints.operation(uf, service, 57) == nil
      end

      assert Endpoints.operation("BA", :mdfe_consulta, 58) == nil
      assert Endpoints.operation("BA", :nfe_consulta_cadastro) == "consultaCadastro"
    end
  end

  describe "the envelope" do
    test "CT-e wraps in cteDadosMsg under the service's own namespace" do
      assert {:ok, envelope} = Envelope.wrap(:cte_status_servico, "<x/>")

      assert envelope =~
               ~s(<cteDadosMsg xmlns="http://www.portalfiscal.inf.br/cte/wsdl/CTeStatusServicoV4"><x/></cteDadosMsg>)

      assert envelope =~ ~s(xmlns:soap="http://www.w3.org/2003/05/soap-envelope")
    end

    test "MDF-e wraps in mdfeDadosMsg" do
      assert {:ok, envelope} = Envelope.wrap(:mdfe_recepcao_sinc, "<x/>")

      assert envelope =~
               ~s(<mdfeDadosMsg xmlns="http://www.portalfiscal.inf.br/mdfe/wsdl/MDFeRecepcaoSinc"><x/></mdfeDadosMsg>)
    end

    test "NF-e keeps nfeDadosMsg" do
      assert {:ok, envelope} = Envelope.wrap(:nfe_status_servico, "<x/>")

      assert envelope =~
               ~s(<nfeDadosMsg xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeStatusServico4"><x/></nfeDadosMsg>)
    end
  end

  describe "the status messages" do
    test "consStatServCTe" do
      assert Envelope.status_service_cte(29, 2) ==
               ~s(<consStatServCTe xmlns="http://www.portalfiscal.inf.br/cte" versao="4.00">) <>
                 ~s(<tpAmb>2</tpAmb><cUF>29</cUF><xServ>STATUS</xServ></consStatServCTe>)
    end

    test "consStatServMDFe has no cUF" do
      assert Envelope.status_service_mdfe(1) ==
               ~s(<consStatServMDFe xmlns="http://www.portalfiscal.inf.br/mdfe" versao="3.00">) <>
                 ~s(<tpAmb>1</tpAmb><xServ>STATUS</xServ></consStatServMDFe>)
    end

    @tag skip: not @have_cte_pl && "SEFAZ_NFE_CTE_PL_PATH or xmllint is not available"
    test "consStatServCTe validates against the XSD" do
      assert validate(Envelope.status_service_cte(29, 2), @cte_pl, "consStatServCTe_v4.00.xsd") ==
               :ok

      assert {:error, _} =
               validate(
                 String.replace(Envelope.status_service_cte(29, 2), "<cUF>29</cUF>", ""),
                 @cte_pl,
                 "consStatServCTe_v4.00.xsd"
               )
    end

    @tag skip: not @have_mdfe_pl && "SEFAZ_NFE_MDFE_PL_PATH or xmllint is not available"
    test "consStatServMDFe validates against the XSD" do
      assert validate(
               Envelope.status_service_mdfe(2),
               @mdfe_pl,
               "consStatServMDFe_v3.00.xsd"
             ) == :ok

      assert {:error, _} =
               validate(
                 String.replace(Envelope.status_service_mdfe(2), "<xServ>STATUS</xServ>", ""),
                 @mdfe_pl,
                 "consStatServMDFe_v3.00.xsd"
               )
    end
  end

  defp validate(xml, pl, schema) do
    path =
      Path.join(System.tmp_dir!(), "sefaz_nfe_status_#{System.unique_integer([:positive])}.xml")

    File.write!(path, xml)

    try do
      case System.cmd("xmllint", ["--noout", "--schema", Path.join(pl, schema), path],
             stderr_to_stdout: true
           ) do
        {_out, 0} -> :ok
        {out, _status} -> {:error, out}
      end
    after
      File.rm(path)
    end
  end
end
