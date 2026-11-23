defmodule SefazNfe.RFBCalculatorGoldenTest do
  @moduledoc """
  The official Receita Federal calculators as an oracle for the IBS, CBS and IS groups
  the builder writes (`test/golden/rfb/README.md`, AD-001, AD-021).

    * `test/golden/rfb/scenarios/*.json`  a calculator request (or, for `roc`, the result
      itself) and a `meta`;
    * `test/golden/rfb/expected/<name>.json`  what the calculator answered;
    * `test/golden/rfb/expected/<name>.xml`  what its `xml/generate` wrote for it;
    * `test/golden/rfb/expected/<name>.validation.json`  its `xml/validate` verdict on OUR
      fragment, built from the same numbers.

  The suite reads those files and never opens a socket;
  `scripts/conformance/rfb_calculator.sh` renders them. The library computes nothing: the
  calculator's numbers go into a minimal NF-e (`SefazNfe.RFBCalculator.builder_map/2`) and
  our `ide/gCompraGov`, `det/imposto/IS`, `det/imposto/IBSCBS`, `total/ISTot` and
  `total/IBSCBSTot` are compared, canonicalised (C14N), with the calculator's.

  The calculators write the layout of NT v1.36; the library targets PL_010_V1.30. What
  differs between the two is listed in `@differences` and `@not_buildable`, each
  asserted exactly, so that the day the PL catches up (or the calculator changes) the
  test says so.
  """

  use ExUnit.Case, async: true

  alias SefazNfe.Fixtures
  alias SefazNfe.Layout
  alias SefazNfe.RFBCalculator, as: RFB
  alias SefazNfe.Signer

  @names RFB.group_names()

  for name <- RFB.names(),
      file <- [".json", ".xml", ".validation.json"],
      File.exists?(Path.join(RFB.dir(), "expected/#{name}#{file}")),
      do: @external_resource(Path.join(RFB.dir(), "expected/#{name}#{file}"))

  # What the calculator writes and our builder does not, as exact canonical pieces of
  # the calculator's fragment: name => [{label, calculator's text, ours, reason}].
  @differences %{
    "regular-is-ad-valorem-ad-rem" => [
      {"det[1]/imposto/IS", "<pISEspec>21.30</pISEspec>", "<adRemIS>21.30</adRemIS>",
       "IS ad rem rate: the calculator's layout (NT v1.36) calls it pISEspec, PL_010_V1.30 " <>
         "adRemIS (the calculator's result carries both names)"}
    ],
    "roc-presumed-credit-zfm" => [
      {"det[1]/imposto/IBSCBS", "<gCredPresIBSZFM><tpCredPresIBSZFM>",
       "<gCredPresIBSZFM><competApur>2027-03</competApur><tpCredPresIBSZFM>",
       "calculator defect: xml/generate drops competApur (a String in the ROC, a gYearMonth " <>
         "in its XML model), so its own xml/validate rejects what it generated"}
    ],
    "roc-tax-refund-devtrib" => [
      {"det[1]/imposto/IBSCBS", "<gDevTrib><vDevTrib>0.10</vDevTrib></gDevTrib>",
       "<gDevTrib><pDevTrib>10.0000</pDevTrib><vDevTrib>0.10</vDevTrib></gDevTrib>",
       "pDevTrib: in PL_010_V1.30 and in the calculator's result, not in its NT v1.36 XML"},
      {"det[1]/imposto/IBSCBS", "<gDevTrib><vDevTrib>0.05</vDevTrib></gDevTrib>",
       "<gDevTrib><pDevTrib>10.0000</pDevTrib><vDevTrib>0.05</vDevTrib></gDevTrib>",
       "pDevTrib (as above)"},
      {"det[1]/imposto/IBSCBS", "<gDevTrib><vDevTrib>0.90</vDevTrib></gDevTrib>",
       "<gDevTrib><pDevTrib>10.0000</pDevTrib><vDevTrib>0.90</vDevTrib></gDevTrib>",
       "pDevTrib (as above)"}
    ]
  }

  # Scenarios whose numbers PL_010_V1.30 has no place for: the builder rejects them with
  # exactly the keys listed. gIBSCBSMono is a different tree in the two layouts
  # (calculator: IBS and CBS side by side in gMonoPadrao/gMonoReten/gMonoRet/gMonoDif;
  # PL_010_V1.30: gIBSMonoAdRem, gIBSMonoAdValorem, ...).
  @not_buildable %{
    "roc-monophase-retention" => ["g_mono_reten", "g_mono_ret"],
    "roc-monophase-standard-deferred" => ["g_mono_dif", "g_mono_padrao"]
  }

  # The calculator's XSD (NT v1.36) refuses what we build, and the reason is the
  # difference listed in `@differences`; any other refusal is a failure.
  @refused %{
    "regular-is-ad-valorem-ad-rem" => ~r/adRemIS/,
    "roc-tax-refund-devtrib" => ~r/pDevTrib/
  }

  @pl System.get_env("SEFAZ_NFE_PL_PATH")
  @have_pl is_binary(@pl) and File.exists?(Path.join(@pl, "nfe_v4.00.xsd")) and
             System.find_executable("xmllint") != nil
  @skip_pl if(@have_pl, do: false, else: "SEFAZ_NFE_PL_PATH or xmllint is not available")

  defp built(name) do
    RFB.build(RFB.scenario(name), RFB.expected_result(name))
  end

  describe "our groups equal the ones the calculator generates" do
    for name <- @names, not Map.has_key?(@not_buildable, name) do
      test name do
        name = unquote(name)
        assert {:ok, %{xml: xml}} = built(name)

        ours = RFB.fragments(xml)

        theirs =
          name
          |> RFB.expected_xml()
          |> RFB.fragments()
          |> Enum.map(fn {label, fragment} ->
            {label, apply_differences(name, label, fragment)}
          end)

        assert Enum.map(ours, &elem(&1, 0)) == Enum.map(theirs, &elem(&1, 0)),
               "#{name}: the two documents do not carry the same groups"

        for {{label, a}, {label, b}} <- Enum.zip(theirs, ours), a != b do
          {calculator, builder} = RFB.first_difference(a, b)
          flunk("#{name} #{label} differs\ncalculator: #{calculator}\nbuilder   : #{builder}")
        end
      end
    end

    for {name, keys} <- @not_buildable do
      test "#{name} is rejected by the builder: PL_010_V1.30 has no place for it" do
        name = unquote(name)
        keys = unquote(keys)

        assert {:error, errors} = built(name)
        assert errors |> Enum.map(&elem(&1, 1)) |> Enum.all?(&(&1 == :unknown_key))

        assert errors |> Enum.map(&(&1 |> elem(0) |> List.last())) |> Enum.sort() ==
                 Enum.sort(keys)

        # What the render recorded is what the builder says today.
        assert %{"built" => false, "errors" => recorded} = RFB.expected_validation(name)
        assert recorded == inspect(errors, limit: :infinity)
      end
    end
  end

  defp apply_differences(name, label, fragment) do
    @differences
    |> Map.get(name, [])
    |> Enum.filter(fn {l, _from, _to, _why} -> l == label end)
    |> Enum.reduce(fragment, fn {_l, from, to, _why}, acc ->
      assert String.contains?(acc, from),
             "#{name} #{label}: the listed difference is gone: #{from}"

      String.replace(acc, from, to, global: false)
    end)
  end

  describe "the calculator's own validation of our fragment (xml/validate, subtipo=grupo)" do
    for name <- @names, not Map.has_key?(@not_buildable, name) do
      test name do
        name = unquote(name)
        verdict = RFB.expected_validation(name)

        case Map.fetch(@refused, name) do
          :error ->
            assert verdict == %{"built" => true, "valid" => true}

          {:ok, reason} ->
            assert %{"built" => true, "valid" => false, "detail" => detail} = verdict
            assert detail =~ reason
        end
      end
    end
  end

  describe "our whole document against PL_010_V1.30 (xmllint)" do
    @describetag skip: @skip_pl

    for name <- @names, not Map.has_key?(@not_buildable, name) do
      test name do
        assert {:ok, %{xml: xml}} = built(unquote(name))
        assert {:ok, signed} = Signer.sign_nfe(xml, Fixtures.cert())
        assert lint(signed) == :ok
      end
    end
  end

  # Simples Nacional: the calculator's result has no element in PL_010_V1.30 (vIBSSN,
  # vCBSSN, pIBSSN, ... are NT 2026.005 fields), so there is nothing to build. The
  # scenarios pin what the calculator answers and that the layout still has no place
  # for it: the day it has, this fails and the mapping gets written.
  describe "Simples Nacional" do
    @simples for name <- RFB.names(), RFB.scenario(name)["meta"]["kind"] == "simples", do: name
    @sn_elements ~w(vRBSNitem tpRBSN vIBSSN vCBSSN pIBSSN pCBSSN vRBSNtot vIBSSNtot vCBSSNtot)

    test "the layout has no Simples Nacional IBS/CBS element yet" do
      tags = Layout.nfe().root |> tags() |> MapSet.new()
      assert Enum.filter(@sn_elements, &MapSet.member?(tags, &1)) == []
    end

    for name <- @simples do
      test "#{name}: the recorded result is complete and adds up" do
        name = unquote(name)
        result = RFB.expected_result(name)
        request = RFB.scenario(name)["request"]

        assert result["oper"]["CRT"] == request["CRT"]
        assert length(result["objetos"]) == length(request["itens"])

        calculated = Enum.filter(result["objetos"], &(&1["estadoItem"] == "CALCULADO"))
        assert calculated != []

        for field <- ["vIBSSN", "vCBSSN"], total = result["total"][field <> "tot"] do
          sum =
            calculated
            |> Enum.map(&Decimal.new(&1["tribCalc"][field]))
            |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

          assert Decimal.equal?(sum, Decimal.new(total)), "#{name}: #{field} does not add up"
        end
      end
    end
  end

  defp tags(%{kind: :element, tag: tag} = node),
    do: [tag | node |> Layout.elements() |> Enum.flat_map(&tags/1)]

  defp tags(_other), do: []

  defp lint(xml) do
    file = Path.join(System.tmp_dir!(), "rfb_golden_#{System.unique_integer([:positive])}.xml")
    File.write!(file, xml)

    try do
      case System.cmd("xmllint", ["--noout", "--schema", "nfe_v4.00.xsd", file],
             cd: @pl,
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, _status} -> output
      end
    after
      File.rm(file)
    end
  end
end
