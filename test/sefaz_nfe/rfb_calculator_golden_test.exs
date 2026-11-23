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

  The calculators write the layout of NT v1.36, whose XSDs predate the official package
  the library targets (PL_010h_v1.03, NT 2026.005/006/008): the calculator still writes
  `pISEspec`, the flat `gMono*` groups and no `pDevTrib`. What differs between the two is
  listed in `@differences` and `@not_buildable`, each asserted exactly, so that the day
  the calculator catches up the test says so.
  """

  use ExUnit.Case, async: true

  alias SefazNfe.Fixtures
  alias SefazNfe.Layout
  alias SefazNfe.RFBCalculator, as: RFB
  alias SefazNfe.Signer
  alias SefazNfe.XML

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
       "IS ad rem rate: the calculator's XSDs (NT v1.36) predate the official PL and still " <>
         "call it pISEspec; PL_010h_v1.03 has adRemIS (the calculator's result carries both)"}
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
       "pDevTrib: in PL_010h_v1.03 and in the calculator's result, not in its older NT v1.36 XML"},
      {"det[1]/imposto/IBSCBS", "<gDevTrib><vDevTrib>0.05</vDevTrib></gDevTrib>",
       "<gDevTrib><pDevTrib>10.0000</pDevTrib><vDevTrib>0.05</vDevTrib></gDevTrib>",
       "pDevTrib (as above)"},
      {"det[1]/imposto/IBSCBS", "<gDevTrib><vDevTrib>0.90</vDevTrib></gDevTrib>",
       "<gDevTrib><pDevTrib>10.0000</pDevTrib><vDevTrib>0.90</vDevTrib></gDevTrib>",
       "pDevTrib (as above)"}
    ]
  }

  # Scenarios whose numbers the official PL has no place for: the builder rejects them with
  # exactly the keys listed. gIBSCBSMono is a different tree in the two layouts: the
  # calculator's XSDs predate the official PL and write IBS and CBS side by side in
  # gMonoPadrao/gMonoReten/gMonoRet/gMonoDif; PL_010h_v1.03 has gIBSMonoAdRem,
  # gIBSMonoAdValorem, ...
  @not_buildable %{
    "roc-monophase-retention" => ["g_mono_reten", "g_mono_ret"],
    "roc-monophase-standard-deferred" => ["g_mono_dif", "g_mono_padrao"]
  }

  # The calculator's older XSD (NT v1.36) refuses what we build, and the reason is the
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
      test "#{name} is rejected by the builder: PL_010h_v1.03 has no place for it" do
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

  describe "our whole document against PL_010h_v1.03 (xmllint)" do
    @describetag skip: @skip_pl

    for name <- @names, not Map.has_key?(@not_buildable, name) do
      test name do
        assert {:ok, %{xml: xml}} = built(unquote(name))
        assert {:ok, signed} = Signer.sign_nfe(xml, Fixtures.cert())
        assert lint(signed) == :ok
      end
    end
  end

  # Simples Nacional (NT 2026.005, in PL_010h_v1.03 as `gTribSN`). The calculator generates
  # no XML for it, so the result is written into our groups
  # (`RFB.build_simples/2`) and compared value by value. What does not map 1:1:
  #
  #   * `TTribSN` only has pIBSSN, vIBSSN, pCBSSN, vCBSSN (item) and vIBSSN, vCBSSN (total);
  #     the calculator also answers vRBSNitem, tpRBSN, vBC (item), vIBSPendSusp,
  #     vCBSPendSusp, vRBSNtot, the *PendSusp totals, IS.valor: no element, not written;
  #   * the total vBC has no gTribSN element, it goes to `total/IBSCBSTot/vBCIBSCBS`,
  #     which the PL requires;
  #   * CRT 2 (excesso de sublimite): the calculator answers only the CBS, no vIBSSNtot,
  #     but `total/IBSCBSTot/gTribSN/vIBSSN` is required: the builder rejects it;
  #   * tpRegimeIBSCBS (`emit`) is in neither the calculator's request nor its result.
  describe "Simples Nacional" do
    @simples for name <- RFB.names(), RFB.scenario(name)["meta"]["kind"] == "simples", do: name
    @sn_not_buildable %{
      "simples-crt2-sublimit" => [{[:total, :ibs_cbs_tot, :g_trib_sn, :v_ibs_sn], :required}]
    }

    test "the layout has the Simples Nacional IBS/CBS elements of NT 2026.005" do
      tags = Layout.nfe().root |> tags() |> MapSet.new()

      for tag <- ~w(tpRegimeIBSCBS cAtivSN gTribSN gIBSSN gCBSSN pIBSSN vIBSSN pCBSSN vCBSSN) do
        assert MapSet.member?(tags, tag), "#{tag} is not in the layout"
      end

      refute MapSet.member?(tags, "vRBSNitem")
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

      if not Map.has_key?(@sn_not_buildable, name) do
        test "#{name}: gTribSN carries the calculator's values, element by element" do
          name = unquote(name)
          result = RFB.expected_result(name)
          request = RFB.scenario(name)["request"]

          assert {:ok, %{xml: xml}} = RFB.build_simples(RFB.scenario(name), result)
          {:ok, doc} = xml |> String.replace(~r/>\s+</, "><") |> XML.parse()
          inf = XML.element(doc, "infNFe")

          assert XML.text(doc, "CRT") == request["CRT"]
          assert XML.all(doc, "tpRegimeIBSCBS") == []

          dets = inf |> XML.children() |> Enum.filter(&(sn_local(&1) == "det"))
          objects = Enum.sort_by(result["objetos"], & &1["nObj"])
          assert length(dets) == length(objects)

          for {det, object} <- Enum.zip(dets, objects) do
            calc = object["tribCalc"]
            item = Enum.at(request["itens"], object["nObj"] - 1)

            assert sn_values(det, ["prod", "cAtivSN"]) == List.wrap(item["cAtivSN"])

            expected =
              for k <- ~w(pIBSSN vIBSSN pCBSSN vCBSSN),
                  object["estadoItem"] == "CALCULADO",
                  calc[k],
                  do: {k, calc[k]}

            assert sn_group(det, ["imposto", "IBSCBS", "gTribSN"]) == Map.new(expected)
          end

          total = result["total"]

          assert sn_group(inf, ["total", "IBSCBSTot", "gTribSN"]) ==
                   %{"vIBSSN" => total["vIBSSNtot"], "vCBSSN" => total["vCBSSNtot"]}

          assert sn_values(inf, ["total", "IBSCBSTot", "vBCIBSCBS"]) == [total["vBC"]]
        end

        test "#{name}: the whole document validates against PL_010h_v1.03 (xmllint)" do
          name = unquote(name)

          if @have_pl do
            assert {:ok, %{xml: xml}} =
                     RFB.build_simples(RFB.scenario(name), RFB.expected_result(name))

            assert {:ok, signed} = Signer.sign_nfe(xml, Fixtures.cert())
            assert lint(signed) == :ok
          end
        end
      end
    end

    for {name, expected} <- @sn_not_buildable do
      test "#{name}: the builder rejects it, the calculator has no vIBSSNtot" do
        name = unquote(name)
        assert {:error, errors} = RFB.build_simples(RFB.scenario(name), RFB.expected_result(name))
        assert errors == unquote(Macro.escape(expected))
        assert RFB.expected_result(name)["total"]["vIBSSNtot"] == nil
      end
    end
  end

  defp sn_local(element), do: element |> XML.qname() |> elem(1)

  defp sn_walk(element, []), do: [element]

  defp sn_walk(element, [name | rest]) do
    element
    |> XML.children()
    |> Enum.filter(&(sn_local(&1) == name))
    |> Enum.flat_map(&sn_walk(&1, rest))
  end

  defp sn_values(element, path), do: element |> sn_walk(path) |> Enum.map(&XML.own_text/1)

  defp sn_group(element, path) do
    for group <- sn_walk(element, path), leaf <- sn_leaves(group), into: %{}, do: leaf
  end

  defp sn_leaves(element) do
    case XML.children(element) do
      [] -> [{sn_local(element), XML.own_text(element)}]
      kids -> Enum.flat_map(kids, &sn_leaves/1)
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
