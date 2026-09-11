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

  test "a snapshot with no date is a problem, not a pass" do
    {_removed, undated} = pop_in(snapshot(), ["snapshot_date"])

    assert ["snapshot_date is missing or not ISO 8601"] = Endpoints.audit(undated)
  end
end
