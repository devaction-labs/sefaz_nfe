defmodule SefazNfe.EndpointsTest do
  use ExUnit.Case, async: true

  alias SefazNfe.Endpoints

  test "SP homologacao NFeAutorizacao4" do
    assert {:ok, url} = Endpoints.url("SP", :homologacao, :nfe_autorizacao)
    assert url =~ "homologacao.nfe.fazenda.sp.gov.br"
    assert url =~ "nfeautorizacao4"
  end

  test "RJ authorizes via SVRS" do
    assert {:ok, url} = Endpoints.url(:rj, :producao, :nfe_status_servico)
    assert {:ok, svrs} = Endpoints.url("SVRS", :producao, :nfe_status_servico)
    assert url == svrs
  end

  test "DistDFe is always Ambiente Nacional" do
    assert {:ok, url} = Endpoints.url("SP", :producao, :nfe_distribuicao_dfe)
    assert url == "https://www1.nfe.fazenda.gov.br/NFeDistribuicaoDFe/NFeDistribuicaoDFe.asmx"
    assert {:ok, ^url} = Endpoints.url("AN", :producao, :nfe_distribuicao_dfe)
  end

  test "unknown service on AN authorization" do
    assert {:error, {:unknown_endpoint, "AN", :nfe_autorizacao}} =
             Endpoints.url("AN", :homologacao, :nfe_autorizacao)
  end

  test "snapshot_date is present" do
    assert Endpoints.snapshot_date() =~ ~r/^\d{4}-\d{2}-\d{2}$/
  end
end
