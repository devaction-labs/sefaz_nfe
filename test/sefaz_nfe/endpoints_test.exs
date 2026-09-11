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
    assert {:error, {:unknown_service, :nfe_consulta_cadastro}} =
             Endpoints.url("SP", :production, :nfe_consulta_cadastro)
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
end
