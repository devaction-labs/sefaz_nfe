defmodule SefazNfe.EndpointsTest do
  use ExUnit.Case, async: true

  alias SefazNfe.Endpoints

  test "SP homologation NFeAutorizacao4" do
    assert {:ok, url} = Endpoints.url("SP", :homologation, :nfe_autorizacao)
    assert url =~ "homologacao.nfe.fazenda.sp.gov.br"
    assert url =~ "nfeautorizacao4"
  end

  test "RJ authorizes via SVRS" do
    assert {:ok, url} = Endpoints.url(:rj, :production, :nfe_status_servico)
    assert {:ok, svrs} = Endpoints.url("SVRS", :production, :nfe_status_servico)
    assert url == svrs
  end

  test "DistDFe is always Ambiente Nacional" do
    assert {:ok, url} = Endpoints.url("SP", :production, :nfe_distribuicao_dfe)
    assert url == "https://www1.nfe.fazenda.gov.br/NFeDistribuicaoDFe/NFeDistribuicaoDFe.asmx"
    assert {:ok, ^url} = Endpoints.url("AN", :production, :nfe_distribuicao_dfe)
  end

  test "unknown service on AN authorization" do
    assert {:error, {:unknown_endpoint, "AN", :nfe_autorizacao}} =
             Endpoints.url("AN", :homologation, :nfe_autorizacao)
  end

  test "invalid environment is not reported as an unknown endpoint" do
    assert {:error, {:invalid_environment, :produção}} =
             Endpoints.url("SP", :produção, :nfe_autorizacao)
  end

  test "unknown service is named as such" do
    assert {:error, {:unknown_service, :nfe_nope}} =
             Endpoints.url("SP", :production, :nfe_nope)
  end

  test "SVC contingency authorizers are reachable by name (AD-005)" do
    assert {:ok, url} = Endpoints.url("SVCRS", :production, :nfe_autorizacao)
    assert url =~ "svrs.rs.gov.br"
  end

  test "every URL in the snapshot is a well-formed SEFAZ address" do
    snapshot = JSON.decode!(File.read!("priv/endpoints/nfe_4.00.json"))

    urls =
      for {_authorizer, environments} <- snapshot["authorizers"],
          {_environment, services} <- environments,
          {_service, url} <- services,
          do: url

    assert length(urls) > 50

    for url <- urls do
      uri = URI.parse(url)

      assert uri.scheme == "https", "not https: #{url}"
      assert is_binary(uri.host), "no host: #{url}"

      assert String.ends_with?(uri.host, ".gov.br"),
             "host is not a government address, the snapshot may have been rewritten: #{url}"
    end
  end

  test "uf_code carries the IBGE code the 4.00 envelopes need as cUF" do
    assert {:ok, 35} = Endpoints.uf_code("SP")
    assert {:ok, 31} = Endpoints.uf_code(:mg)
    assert {:ok, 91} = Endpoints.uf_code("AN")
    assert {:error, {:unknown_uf, "XX"}} = Endpoints.uf_code("XX")
  end

  test "snapshot_date is present" do
    assert Endpoints.snapshot_date() =~ ~r/^\d{4}-\d{2}-\d{2}$/
  end

  describe "model 65 (NFC-e)" do
    test "the 3-arity form is still model 55" do
      assert Endpoints.url("BA", :homologation, :nfe_autorizacao) ==
               Endpoints.url("BA", :homologation, :nfe_autorizacao, 55)

      assert {:ok, "https://hnfe.sefaz.ba.gov.br" <> _} =
               Endpoints.url("BA", :homologation, :nfe_autorizacao)
    end

    test "BA is served by SVRS for model 65, unlike model 55" do
      assert {:ok, url} = Endpoints.url("BA", :production, :nfe_autorizacao, 65)
      assert url == "https://nfce.svrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx"
      assert {:ok, ^url} = Endpoints.url("SVRS", :production, :nfe_autorizacao, 65)
    end

    test "MA and PE have no SVAN or own table for model 65" do
      assert {:ok, ma} = Endpoints.url("MA", :production, :nfe_status_servico, 65)
      assert {:ok, ^ma} = Endpoints.url("SVRS", :production, :nfe_status_servico, 65)
      assert {:ok, pe} = Endpoints.url("PE", :production, :nfe_status_servico, 65)
      assert pe == ma
    end

    test "SP runs its own NFC-e authorizer" do
      assert {:ok, "https://homologacao.nfce.fazenda.sp.gov.br/ws/NFeAutorizacao4.asmx"} =
               Endpoints.url("SP", :homologation, :nfe_autorizacao, 65)

      assert {:ok, "https://nfce.fazenda.sp.gov.br/ws/NFeRecepcaoEvento4.asmx"} =
               Endpoints.url("SP", :production, :nfe_recepcao_evento, 65)
    end

    test "the eight own authorizers are AM GO MG MS MT PR RS SP" do
      snapshot = JSON.decode!(File.read!("priv/endpoints/nfce_4.00.json"))

      own = for {uf, authorizer} <- snapshot["uf_authorizer"], uf == authorizer, do: uf
      assert Enum.sort(own) == ~w(AM GO MG MS MT PR RS SP)
      assert map_size(snapshot["uf_authorizer"]) == 27
    end

    test "every UF resolves all six services in both environments" do
      services =
        ~w(nfe_autorizacao nfe_ret_autorizacao nfe_consulta_protocolo
           nfe_status_servico nfe_inutilizacao nfe_recepcao_evento)a

      snapshot = JSON.decode!(File.read!("priv/endpoints/nfce_4.00.json"))

      for uf <- Map.keys(snapshot["uf_authorizer"]),
          environment <- [:homologation, :production],
          service <- services do
        assert {:ok, _url} = Endpoints.url(uf, environment, service, 65), "#{uf} #{service}"
      end
    end

    test "DistDFe and the registry are not model 65 services" do
      assert {:error, {:unknown_endpoint, "SP", :nfe_distribuicao_dfe}} =
               Endpoints.url("SP", :production, :nfe_distribuicao_dfe, 65)

      assert {:error, {:unknown_endpoint, "SP", :nfe_consulta_cadastro}} =
               Endpoints.url("SP", :production, :nfe_consulta_cadastro, 65)
    end

    test "an unsupported model is named" do
      assert {:error, {:unsupported_model, 57}} =
               Endpoints.url("SP", :production, :nfe_autorizacao, 57)
    end

    test "qr_code_url is the emitting UF's, also for an SVRS UF" do
      assert {:ok, "http://hnfe.sefaz.ba.gov.br/servicos/nfce/qrcode.aspx"} =
               Endpoints.qr_code_url("BA", :homologation)

      assert {:ok, "http://nfe.sefaz.ba.gov.br/servicos/nfce/qrcode.aspx"} =
               Endpoints.qr_code_url(:ba, :production)

      assert {:ok, "https://www.nfce.fazenda.sp.gov.br/qrcode"} =
               Endpoints.qr_code_url("SP", :production)

      assert {:ok, "https://www.homologacao.nfce.fazenda.sp.gov.br/qrcode"} =
               Endpoints.qr_code_url("SP", :homologation)
    end

    test "url_chave is kept exactly as published, scheme or not" do
      assert {:ok, "http://www.sefaz.ba.gov.br/nfce/consulta"} =
               Endpoints.url_chave("BA", :production)

      assert {:ok, "http://hinternet.sefaz.ba.gov.br/nfce/consulta"} =
               Endpoints.url_chave("BA", :homologation)

      assert {:ok, "https://www.homologacao.nfce.fazenda.sp.gov.br/NFCeConsultaPublica"} =
               Endpoints.url_chave("SP", :homologation)

      assert {:ok, "www.sefaznet.ac.gov.br/nfce/consulta"} =
               Endpoints.url_chave("AC", :production)
    end

    test "qr_code_url and url_chave know every UF in both environments" do
      snapshot = JSON.decode!(File.read!("priv/endpoints/nfce_4.00.json"))

      for uf <- Map.keys(snapshot["uf_authorizer"]),
          environment <- [:homologation, :production] do
        assert {:ok, _qr} = Endpoints.qr_code_url(uf, environment)
        assert {:ok, _chave} = Endpoints.url_chave(uf, environment)
      end
    end

    test "address lookups fail by name" do
      assert {:error, {:unknown_endpoint, "XX", :qr_code}} =
               Endpoints.qr_code_url("XX", :production)

      assert {:error, {:unknown_endpoint, "XX", :url_chave}} =
               Endpoints.url_chave("XX", :production)

      assert {:error, {:invalid_environment, :prod}} = Endpoints.qr_code_url("SP", :prod)
    end
  end
end
