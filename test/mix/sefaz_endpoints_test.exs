defmodule Mix.Tasks.Sefaz.EndpointsTest do
  @moduledoc """
  The audit exists to catch a hand-edited table before production does, so it
  is tested against tables that are actually broken. Its first version passed a
  snapshot whose UF pointed at a missing authorizer: `url = get_in(...)` inside
  a comprehension binds `nil`, which is falsy, so the entry was filtered out
  instead of reported.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Sefaz.Endpoints

  defp snapshot, do: JSON.decode!(File.read!("priv/endpoints/nfe_4.00.json"))

  test "the vendored snapshot is clean" do
    assert [] = Endpoints.audit(snapshot())
  end

  test "a UF pointing at a missing authorizer is reported for every service" do
    broken = put_in(snapshot(), ["uf_authorizer", "SP"], "NOPE")

    problems = Endpoints.audit(broken)

    assert length(problems) == 12
    assert Enum.all?(problems, &String.contains?(&1, "SP (NOPE)"))
  end

  test "a missing service URL is reported, not skipped" do
    {_removed, broken} =
      pop_in(snapshot(), ["authorizers", "SP", "production", "nfe_autorizacao"])

    assert ["SP (SP) has no production nfe_autorizacao"] = Endpoints.audit(broken)
  end

  test "an empty service URL counts as missing" do
    broken = put_in(snapshot(), ["authorizers", "SP", "production", "nfe_autorizacao"], "")

    assert ["SP (SP) has no production nfe_autorizacao"] = Endpoints.audit(broken)
  end

  test "a URL rewritten to a non-government host is caught" do
    path = ["authorizers", "MG", "homologation", "nfe_status_servico"]
    broken = put_in(snapshot(), path, "https://evil.test/x")

    assert [problem] = Endpoints.audit(broken)
    assert problem =~ "host is not a government address"
  end

  test "plain http is refused" do
    path = ["authorizers", "MG", "homologation", "nfe_status_servico"]
    broken = put_in(snapshot(), path, "http://nfe.fazenda.mg.gov.br/x")

    assert [problem] = Endpoints.audit(broken)
    assert problem =~ "not https"
  end

  test "a UF with no IBGE code is caught, since the envelope needs cUF" do
    {_removed, broken} = pop_in(snapshot(), ["uf_code", "SP"])

    assert ["SP has no IBGE uf_code"] = Endpoints.audit(broken)
  end

  test "a stale snapshot fails the age check" do
    stale = put_in(snapshot(), ["snapshot_date"], "2024-01-01")

    assert [problem] = Endpoints.audit(stale)
    assert problem =~ "days old"
  end

  test "an operations override for an unknown authorizer is reported" do
    broken =
      put_in(snapshot(), ["operations", "nfe_consulta_cadastro", "NOPE"], "consultaCadastro")

    assert ["operations nfe_consulta_cadastro names unknown authorizer NOPE"] =
             Endpoints.audit(broken)
  end

  test "an operations entry with no default is reported" do
    {_removed, broken} = pop_in(snapshot(), ["operations", "nfe_consulta_cadastro", "default"])

    assert ["operations nfe_consulta_cadastro has no default"] = Endpoints.audit(broken)
  end

  test "a snapshot with no date is a problem, not a pass" do
    {_removed, undated} = pop_in(snapshot(), ["snapshot_date"])

    assert ["snapshot_date is missing or not ISO 8601"] = Endpoints.audit(undated)
  end

  describe "the model 65 table" do
    defp nfce, do: JSON.decode!(File.read!("priv/endpoints/nfce_4.00.json"))

    test "the vendored NFC-e snapshot is clean" do
      assert [] = Endpoints.audit(nfce())
    end

    test "a UF missing its production qr_code is reported" do
      {_removed, broken} = pop_in(nfce(), ["qr_code", "production", "BA"])

      assert ["BA has no production qr_code"] = Endpoints.audit(broken)
    end

    test "a UF missing its homologation url_chave is reported" do
      {_removed, broken} = pop_in(nfce(), ["url_chave", "homologation", "SP"])

      assert ["SP has no homologation url_chave"] = Endpoints.audit(broken)
    end

    test "a qr_code pointing off .gov.br is caught, but plain http is allowed" do
      broken = put_in(nfce(), ["qr_code", "production", "BA"], "http://evil.test/qr")

      assert [problem] = Endpoints.audit(broken)
      assert problem =~ "host is not a government address"

      http = put_in(nfce(), ["qr_code", "production", "BA"], "http://nfe.sefaz.ba.gov.br/qr")
      assert [] = Endpoints.audit(http)
    end

    test "url_chave is not held to https or a scheme, only to the XSD length" do
      schemeless =
        put_in(nfce(), ["url_chave", "production", "BA"], "www.sefaz.ba.gov.br/nfce/consulta")

      assert [] = Endpoints.audit(schemeless)

      short = put_in(nfce(), ["url_chave", "production", "BA"], "a.gov.br")
      assert [problem] = Endpoints.audit(short)
      assert problem =~ "url_chave: not 21 to 85 characters"
    end

    test "webservice URLs keep the https and .gov.br rule" do
      path = ["authorizers", "SP", "production", "nfe_autorizacao"]

      assert [problem] = Endpoints.audit(put_in(nfce(), path, "http://nfce.fazenda.sp.gov.br/x"))
      assert problem =~ "not https"

      assert [problem] = Endpoints.audit(put_in(nfce(), path, "https://evil.test/x"))
      assert problem =~ "host is not a government address"
    end

    test "a UF pointing at a missing authorizer is reported" do
      broken = put_in(nfce(), ["uf_authorizer", "BA"], "NOPE")

      problems = Endpoints.audit(broken)
      assert length(problems) == 12
      assert Enum.all?(problems, &String.contains?(&1, "BA (NOPE)"))
    end

    test "no IBGE uf_code is demanded of it, those live in the model 55 table" do
      refute Map.has_key?(nfce(), "uf_code")
      assert [] = Endpoints.audit(nfce())
    end
  end

  describe "uf_contingency" do
    test "a UF with no entry is reported" do
      {_removed, broken} = pop_in(snapshot(), ["uf_contingency", "SP"])

      assert ["SP has no uf_contingency entry"] = Endpoints.audit(broken)
    end

    test "an entry that is not an SVC is reported" do
      broken = put_in(snapshot(), ["uf_contingency", "SP"], "SP")

      assert [problem] = Endpoints.audit(broken)
      assert problem =~ "SP uf_contingency"
      assert problem =~ "not SVCAN or SVCRS"
    end

    test "an SVC missing a service is reported for each UF it serves" do
      {_removed, broken} =
        pop_in(snapshot(), ["authorizers", "SVCRS", "production", "nfe_recepcao_evento"])

      problems = Endpoints.audit(broken)
      assert length(problems) == 8
      assert Enum.all?(problems, &(&1 =~ "SVCRS has no production nfe_recepcao_evento"))
    end

    test "the NFC-e table has none and is not asked for one" do
      nfce = JSON.decode!(File.read!("priv/endpoints/nfce_4.00.json"))

      refute Map.has_key?(nfce, "uf_contingency")
      assert [] = Endpoints.audit(nfce)
    end
  end

  describe "the CT-e table" do
    defp cte, do: JSON.decode!(File.read!("priv/endpoints/cte_4.00.json"))

    test "the vendored CT-e snapshot is clean" do
      assert [] = Endpoints.audit(cte())
    end

    test "a UF pointing at a missing authorizer is reported per service" do
      broken = put_in(cte(), ["uf_authorizer", "BA"], "NOPE")

      problems = Endpoints.audit(broken)

      # five services in two environments
      assert length(problems) == 10
      assert Enum.all?(problems, &String.contains?(&1, "BA (NOPE)"))
    end

    test "a missing CT-e OS URL is reported" do
      {_removed, broken} =
        pop_in(cte(), ["authorizers", "MS", "homologation", "cte_recepcao_os"])

      assert ["MS (MS) has no homologation cte_recepcao_os"] = Endpoints.audit(broken)
    end

    test "a URL off .gov.br is caught" do
      path = ["authorizers", "SVRS", "production", "cte_consulta"]
      broken = put_in(cte(), path, "https://evil.test/x")

      assert [problem] = Endpoints.audit(broken)
      assert problem =~ "host is not a government address"
    end

    test "a UF with no contingency entry is reported" do
      {_removed, broken} = pop_in(cte(), ["uf_contingency", "BA"])

      assert ["BA has no uf_contingency entry"] = Endpoints.audit(broken)
    end

    test "SVCAN is not a CT-e contingency" do
      broken = put_in(cte(), ["uf_contingency", "BA"], "SVCAN")

      assert ["BA uf_contingency \"SVCAN\" is not SVCSP or SVCRS"] = Endpoints.audit(broken)
    end

    test "a contingency authorizer that does not exist is reported" do
      broken = put_in(cte(), ["contingency_authorizer", "SVCSP"], "NOPE")

      problems = Endpoints.audit(broken)

      assert length(problems) == 10
      assert Enum.all?(problems, &String.contains?(&1, "SVCSP contingency_authorizer NOPE"))
    end

    test "the IBGE code is not demanded of the CT-e table" do
      refute Enum.any?(Endpoints.audit(cte()), &String.contains?(&1, "uf_code"))
    end
  end

  describe "the MDF-e table" do
    defp mdfe, do: JSON.decode!(File.read!("priv/endpoints/mdfe_3.00.json"))

    test "the vendored MDF-e snapshot is clean" do
      assert [] = Endpoints.audit(mdfe())
    end

    test "a missing service URL is reported" do
      {_removed, broken} =
        pop_in(mdfe(), ["authorizers", "SVRS", "production", "mdfe_consulta_nao_enc"])

      # every UF points at SVRS
      problems = Endpoints.audit(broken)
      assert length(problems) == 27

      assert Enum.all?(
               problems,
               &String.contains?(&1, "(SVRS) has no production mdfe_consulta_nao_enc")
             )
    end

    test "every UF is covered, so a UF with no authorizer entry cannot go unnoticed" do
      assert map_size(mdfe()["uf_authorizer"]) == 27
      assert mdfe()["uf_authorizer"] |> Map.values() |> Enum.uniq() == ["SVRS"]
    end
  end
end
