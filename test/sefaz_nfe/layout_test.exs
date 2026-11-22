defmodule SefazNfe.LayoutTest do
  @moduledoc """
  Audits the committed `priv/layouts/nfe_4.00.etf` (no XSD needed): the order of
  `infNFe`, the choices, the facets and the attributes are what the builder
  will rely on, so a regeneration that moves one must be noticed here.
  """

  use ExUnit.Case, async: true

  alias SefazNfe.Layout

  defp find!(path), do: Layout.find(Layout.nfe(), path) || flunk("no element at #{inspect(path)}")
  defp tags(node), do: node |> Layout.elements() |> Enum.map(& &1.tag)

  test "records where it came from" do
    layout = Layout.nfe()

    assert layout.pl == "PL_010_V1.30"
    assert layout.generator == 1
    assert layout.root_type == "TNFe"
    assert layout.namespace == "http://www.portalfiscal.inf.br/nfe"

    assert Enum.map(layout.sources, & &1.file) == [
             "DFeTiposBasicos_v1.00.xsd",
             "leiauteNFe_v4.00.xsd",
             "nfe_v4.00.xsd",
             "tiposBasico_v4.00.xsd",
             "xmldsig-core-schema_v1.01.xsd"
           ]

    assert Enum.all?(layout.sources, &(&1.sha256 =~ ~r/\A[0-9a-f]{64}\z/))
  end

  test "the root is NFe, with infNFe, infNFeSupl and an opaque Signature" do
    root = Layout.nfe().root

    assert %{kind: :element, tag: "NFe", key: :nfe} = root
    assert tags(root) == ["infNFe", "infNFeSupl", "Signature"]

    assert %{kind: :foreign, key: :signature, ns: "http://www.w3.org/2000/09/xmldsig#"} =
             Layout.find(root, ["Signature"])

    assert %{min: 0, max: 1} = Layout.find(root, [:inf_nfe_supl])
  end

  test "infNFe keeps the XSD order and occurrences" do
    inf_nfe = find!([:inf_nfe])

    assert inf_nfe.content.kind == :sequence

    assert Enum.map(Layout.elements(inf_nfe), &{&1.tag, &1.min, &1.max}) == [
             {"ide", 1, 1},
             {"emit", 1, 1},
             {"avulsa", 0, 1},
             {"dest", 0, 1},
             {"retirada", 0, 1},
             {"entrega", 0, 1},
             {"autXML", 0, 10},
             {"det", 1, 990},
             {"total", 1, 1},
             {"transp", 1, 1},
             {"cobr", 0, 1},
             {"pag", 1, 1},
             {"infIntermed", 0, 1},
             {"gPgtoVinc", 0, 1},
             {"infAdic", 0, 1},
             {"exporta", 0, 1},
             {"compra", 0, 1},
             {"cana", 0, 1},
             {"infRespTec", 0, 1},
             {"infSolicNFF", 0, 1},
             {"agropecuario", 0, 1},
             {"infPAA", 0, 1}
           ]
  end

  test "infNFe and det attributes" do
    assert [versao, id] = find!([:inf_nfe]).attrs

    assert %{name: "versao", key: :versao, use: :required, type: %{pattern: "4\\.00"}} = versao
    assert %{name: "Id", key: :id, use: :required, type: %{base: :id}} = id
    assert id.type.pattern == "NFe[0-9]{6}[0-9A-Z]{12}[0-9]{26}"

    assert [%{name: "nItem", key: :n_item, use: :required}] = find!([:inf_nfe, :det]).attrs
  end

  test "a named complex type is expanded and remembered" do
    assert %{type_name: "TEnderEmi", content: %{kind: :sequence}} =
             find!([:inf_nfe, :emit, :ender_emit])

    assert %{type_name: nil} = find!([:inf_nfe, :emit])
  end

  test "ICMS is a choice with every variant, in order" do
    icms = find!([:inf_nfe, :det, :imposto, :icms])

    assert %{kind: :choice, min: 1, max: 1, children: variants} = icms.content
    variant_tags = Enum.map(variants, & &1.tag)

    for tag <-
          ~w(ICMS00 ICMS10 ICMS20 ICMS40 ICMS51 ICMS60 ICMS70 ICMS90 ICMSPart ICMSST
             ICMSSN101 ICMSSN102 ICMSSN201 ICMSSN202 ICMSSN500 ICMSSN900) do
      assert tag in variant_tags
    end

    assert hd(variant_tags) == "ICMS00"
    assert variants |> Enum.map(& &1.key) |> Enum.take(3) == [:icms00, :icms02, :icms10]
    assert :icmssn102 in Enum.map(variants, & &1.key)
  end

  test "a sequence nested in a choice and a choice nested in a sequence are kept" do
    pairs = groups([Layout.nfe().root])

    assert {:choice, :sequence} in pairs
    assert {:sequence, :choice} in pairs
  end

  defp groups(nodes) do
    Enum.flat_map(nodes, fn
      %{kind: kind, children: children} when kind in [:sequence, :choice] ->
        own = for %{kind: inner} when inner in [:sequence, :choice] <- children, do: {kind, inner}
        own ++ groups(children)

      %{kind: :element, content: %{kind: _kind} = content} ->
        groups([content])

      _leaf_or_foreign ->
        []
    end)
  end

  test "TDec_1302 is resolved to its facets on ICMSTot/vNF" do
    assert %{
             content: %{
               base: :string,
               name: "TDec_1302",
               pattern: "0|0\\.[0-9]{2}|[1-9]{1}[0-9]{0,12}(\\.[0-9]{2})?",
               white_space: :preserve,
               inherited_patterns: []
             }
           } = find!([:inf_nfe, :total, :icms_tot, :v_nf])
  end

  test "a restriction chain keeps the length facets and the name of the type" do
    assert %{content: %{name: "TCnpj", pattern: "[0-9A-Z]{12}[0-9]{2}", max_length: 14}} =
             find!([:inf_nfe, :emit, :cnpj])

    assert %{content: %{base: :string, enum: ["1", "2"]}} = find!([:inf_nfe, :ide, :tp_amb])
  end

  test "a pattern added to an inherited one is an AND, not a replacement" do
    assert %{content: %{pattern: "[0-9]{11}|[0-9]{13}|ISENTO", inherited_patterns: [inherited]}} =
             find!([:inf_nfe, :det, :prod, :med, :c_prod_anvisa])

    assert inherited =~ "[!-"
  end

  test "IBS/CBS groups from NT 2025.002 are present" do
    assert %{kind: :element, key: :ibscbs} = find!([:inf_nfe, :det, :imposto, :ibscbs])
    assert "IBSCBS" in tags(find!([:inf_nfe, :det, :imposto]))
    assert "gIBSCBS" in tags(find!([:inf_nfe, :det, :imposto, :ibscbs]))

    g_ibscbs = find!([:inf_nfe, :det, :imposto, :ibscbs, :g_ibscbs])

    for key <- [:v_bc, :g_ibsuf, :g_ibs_mun, :v_ibs, :g_cbs] do
      assert Enum.any?(Layout.elements(g_ibscbs), &(&1.key == key)), "missing #{key}"
    end

    assert %{key: :ibs_cbs_tot} = find!([:inf_nfe, :total, :ibs_cbs_tot])
    assert %{key: :is_tot} = find!([:inf_nfe, :total, :is_tot])
  end

  test "find/2 accepts tags as well as keys and returns nil for a missing path" do
    assert Layout.find(Layout.nfe(), ["infNFe", "det", "prod"]) ==
             Layout.find(Layout.nfe(), [:inf_nfe, :det, :prod])

    assert Layout.find(Layout.nfe(), [:inf_nfe, :nope]) == nil
  end

  test "different tags never share a key under one element" do
    for element <- all_elements([Layout.nfe().root]) do
      children = Layout.elements(element)
      by_key = children |> Enum.group_by(& &1.key, & &1.tag) |> Map.values()
      assert Enum.all?(by_key, &(&1 |> Enum.uniq() |> length() == 1)), "under #{element.tag}"
    end
  end

  defp all_elements(nodes) do
    Enum.flat_map(nodes, fn
      %{kind: :element} = element -> [element | all_elements(Layout.elements(element))]
      _other -> []
    end)
  end
end
