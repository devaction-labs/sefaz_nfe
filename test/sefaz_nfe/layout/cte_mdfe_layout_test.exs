defmodule SefazNfe.Layout.CteMdfeLayoutTest do
  @moduledoc """
  Audits the committed CT-e, CT-e OS, MDF-e and road-modal layouts (no XSD
  needed): the order of `infCte` / `infMDFe`, the choices, the `infModal`
  `xs:any` and the attributes are what the builder will rely on (C3), so a
  regeneration that moves one must be noticed here.
  """

  use ExUnit.Case, async: true

  alias SefazNfe.Layout

  @cte_ns "http://www.portalfiscal.inf.br/cte"
  @mdfe_ns "http://www.portalfiscal.inf.br/mdfe"

  defp tags(node), do: node |> Layout.elements() |> Enum.map(& &1.tag)
  defp shape(node), do: node |> Layout.elements() |> Enum.map(&{&1.tag, &1.min, &1.max})

  defp find!(layout, path),
    do: Layout.find(layout, path) || flunk("no element at #{inspect(path)}")

  describe "provenance" do
    test "CT-e and CT-e OS come from PL_CTe_400_RTC" do
      for {layout, root_type, root} <- [
            {Layout.cte(), "TCTe", "CTe"},
            {Layout.cte_os(), "TCTeOS", "CTeOS"}
          ] do
        assert layout.pl == "PL_CTe_400_RTC"
        assert layout.namespace == @cte_ns
        assert layout.root_type == root_type
        assert layout.root.tag == root
        assert "cteTiposBasico_v4.00.xsd" in Enum.map(layout.sources, & &1.file)
        assert Enum.all?(layout.sources, &(&1.sha256 =~ ~r/\A[0-9a-f]{64}\z/))
      end
    end

    test "MDF-e comes from PL_MDFe_300b" do
      layout = Layout.mdfe()

      assert layout.pl == "PL_MDFe_300b"
      assert layout.namespace == @mdfe_ns
      assert layout.root_type == "TMDFe"
      assert layout.root.tag == "MDFe"
      assert "mdfeTiposBasico_v3.00.xsd" in Enum.map(layout.sources, & &1.file)
    end

    test "the road modals are rooted at a global element, not a type" do
      for {modal, ns, root} <- [
            {:cte_rodo, @cte_ns, "rodo"},
            {:cte_os_rodo, @cte_ns, "rodoOS"},
            {:mdfe_rodo, @mdfe_ns, "rodo"}
          ] do
        layout = Layout.modal(modal)

        assert layout.namespace == ns
        assert layout.root_type == nil
        assert layout.root_element == root
        assert layout.root.tag == root
      end
    end
  end

  describe "CT-e" do
    test "CTe holds infCte, infCTeSupl and an opaque Signature" do
      assert tags(Layout.cte().root) == ["infCte", "infCTeSupl", "Signature"]
      assert %{kind: :foreign} = find!(Layout.cte(), ["Signature"])
    end

    test "infCte has Id and versao attributes, and keeps the XSD order" do
      inf = find!(Layout.cte(), [:inf_cte])

      assert Enum.map(inf.attrs, &{&1.name, &1.use}) == [
               {"versao", :required},
               {"Id", :required}
             ]

      assert [%{pattern: "4\\.00"}, %{pattern: id}] = Enum.map(inf.attrs, & &1.type)
      assert id == "CTe[0-9]{6}[A-Z0-9]{12}[0-9]{26}"

      assert shape(inf) == [
               {"ide", 1, 1},
               {"compl", 0, 1},
               {"emit", 1, 1},
               {"rem", 0, 1},
               {"exped", 0, 1},
               {"receb", 0, 1},
               {"dest", 0, 1},
               {"vPrest", 1, 1},
               {"imp", 1, 1},
               {"pgtoVinc", 0, 1},
               {"infCTeNorm", 1, 1},
               {"infCteComp", 1, 10},
               {"autXML", 0, 10},
               {"infRespTec", 0, 1},
               {"infSolicNFF", 0, 1},
               {"infPAA", 0, 1}
             ]
    end

    test "infCTeNorm and infCteComp are the two branches of one choice" do
      %{content: %{kind: :sequence, children: children}} = find!(Layout.cte(), [:inf_cte])

      assert %{kind: :choice, min: 1, max: 1, children: [norm, comp]} =
               Enum.find(children, &(&1.kind == :choice))

      assert %{tag: "infCTeNorm", key: :inf_cte_norm} = norm
      assert %{tag: "infCteComp", key: :inf_cte_comp, max: 10} = comp
      assert tags(comp) == ["chCTe"]
    end

    test "infCTeNorm order" do
      assert shape(find!(Layout.cte(), [:inf_cte, :inf_cte_norm])) == [
               {"infCarga", 1, 1},
               {"infDoc", 0, 1},
               {"docAnt", 0, 1},
               {"infModal", 1, 1},
               {"veicNovos", 0, :unbounded},
               {"cobr", 0, 1},
               {"infCteSub", 0, 1},
               {"infGlobalizado", 0, 1},
               {"infServVinc", 0, 1}
             ]
    end

    test "infModal is an xs:any with a required versaoModal attribute" do
      modal = find!(Layout.cte(), [:inf_cte, :inf_cte_norm, :inf_modal])

      assert [%{name: "versaoModal", key: :versao_modal, use: :required}] = modal.attrs

      assert %{
               kind: :sequence,
               children: [
                 %{
                   kind: :any,
                   namespace: "##any",
                   process_contents: :skip,
                   min: 1,
                   max: 1
                 }
               ]
             } = modal.content

      assert Layout.elements(modal) == []
    end

    test "the ICMS choice has the seven CT-e variants" do
      icms = find!(Layout.cte(), [:inf_cte, :imp, :icms])

      assert %{kind: :choice, min: 1, max: 1} = icms.content

      assert shape(icms) == [
               {"ICMS00", 1, 1},
               {"ICMS20", 1, 1},
               {"ICMS45", 1, 1},
               {"ICMS60", 1, 1},
               {"ICMS90", 1, 1},
               {"ICMSOutraUF", 1, 1},
               {"ICMSSN", 1, 1}
             ]

      assert [:icms00, :icms20, :icms45, :icms60, :icms90, :icms_outra_uf, :icms_sn] ==
               icms |> Layout.elements() |> Enum.map(& &1.key)
    end

    test "imp carries the IBS/CBS groups of the RTC" do
      assert tags(find!(Layout.cte(), [:inf_cte, :imp])) ==
               ["ICMS", "vTotTrib", "infAdFisco", "ICMSUFFim", "IBSCBS", "vTotDFe"]

      assert shape(find!(Layout.cte(), [:inf_cte, :imp, :ibs_cbs])) == [
               {"CST", 1, 1},
               {"cClassTrib", 1, 1},
               {"indDoacao", 0, 1},
               {"gIBSCBS", 0, 1},
               {"gEstornoCred", 0, 1}
             ]

      assert shape(find!(Layout.cte(), [:inf_cte, :imp, :ibs_cbs, :g_ibs_cbs])) == [
               {"vBC", 1, 1},
               {"gIBSUF", 1, 1},
               {"gIBSMun", 1, 1},
               {"vIBS", 1, 1},
               {"gCBS", 1, 1},
               {"gTribRegular", 0, 1},
               {"gTribCompraGov", 0, 1}
             ]
    end

    test "ide starts with the key fields and refDFeAnt is free text" do
      ide = find!(Layout.cte(), [:inf_cte, :ide])

      assert ide |> tags() |> Enum.take(14) ==
               ~w(cUF cCT CFOP natOp mod serie nCT dhEmi tpImp tpEmis cDV tpAmb tpCTe procEmi)

      assert %{min: 0, max: :unbounded, content: %{base: :any_type}} =
               find!(Layout.cte(), [:inf_cte, :ide, :g_compra_gov, :ref_dfe_ant])
    end
  end

  describe "CT-e OS" do
    test "CTeOS has a versao attribute and the same top level" do
      assert [%{name: "versao", use: :required}] = Layout.cte_os().root.attrs
      assert tags(Layout.cte_os().root) == ["infCte", "infCTeSupl", "Signature"]
    end

    test "infCte order" do
      inf = find!(Layout.cte_os(), [:inf_cte])

      assert Enum.map(inf.attrs, & &1.name) == ["versao", "Id"]

      assert shape(inf) == [
               {"ide", 1, 1},
               {"compl", 0, 1},
               {"emit", 1, 1},
               {"toma", 0, 1},
               {"vPrest", 1, 1},
               {"imp", 1, 1},
               {"pgtoVinc", 0, 1},
               {"infCTeNorm", 1, 1},
               {"infCteComp", 1, 10},
               {"autXML", 0, 10},
               {"infRespTec", 0, 1}
             ]
    end

    test "infCTeNorm has an optional infModal xs:any, and the ICMS choice is there" do
      norm = find!(Layout.cte_os(), [:inf_cte, :inf_cte_norm])

      assert tags(norm) ==
               ~w(infServico infDocRef seg infModal infCteSub refCTeCanc cobr infGTVe)

      modal = find!(Layout.cte_os(), [:inf_cte, :inf_cte_norm, :inf_modal])
      assert modal.min == 0
      assert [%{kind: :any, process_contents: :skip}] = modal.content.children

      assert %{kind: :choice} = find!(Layout.cte_os(), [:inf_cte, :imp, :icms]).content
      assert %{tag: "IBSCBS"} = find!(Layout.cte_os(), [:inf_cte, :imp, :ibs_cbs])
    end
  end

  describe "MDF-e" do
    test "MDFe holds infMDFe, infMDFeSupl and an opaque Signature" do
      assert tags(Layout.mdfe().root) == ["infMDFe", "infMDFeSupl", "Signature"]
    end

    test "infMDFe keeps the XSD order, with Id and versao" do
      inf = find!(Layout.mdfe(), [:inf_mdfe])

      assert Enum.map(inf.attrs, &{&1.name, &1.use}) == [
               {"versao", :required},
               {"Id", :required}
             ]

      assert shape(inf) == [
               {"ide", 1, 1},
               {"emit", 1, 1},
               {"infModal", 1, 1},
               {"infDoc", 1, 1},
               {"seg", 0, :unbounded},
               {"prodPred", 0, 1},
               {"tot", 1, 1},
               {"lacres", 0, :unbounded},
               {"autXML", 0, 10},
               {"infAdic", 0, 1},
               {"infRespTec", 0, 1},
               {"infSolicNFF", 0, 1},
               {"infPAA", 0, 1}
             ]
    end

    test "infModal is an xs:any with a required versaoModal" do
      modal = find!(Layout.mdfe(), [:inf_mdfe, :inf_modal])

      assert [%{name: "versaoModal", use: :required}] = modal.attrs
      assert [%{kind: :any, process_contents: :skip}] = modal.content.children
    end

    test "infDoc and tot" do
      assert shape(find!(Layout.mdfe(), [:inf_mdfe, :inf_doc])) == [{"infMunDescarga", 1, 1000}]

      assert shape(find!(Layout.mdfe(), [:inf_mdfe, :tot])) == [
               {"qCTe", 0, 1},
               {"qNFe", 0, 1},
               {"qMDFe", 0, 1},
               {"vCarga", 1, 1},
               {"cUnid", 1, 1},
               {"qCarga", 1, 1}
             ]
    end
  end

  describe "road modals" do
    test "CT-e rodo" do
      assert shape(Layout.modal(:cte_rodo).root) == [{"RNTRC", 1, 1}, {"occ", 0, 10}]
    end

    test "CT-e OS rodoOS" do
      assert shape(Layout.modal(:cte_os_rodo).root) == [
               {"TAF", 1, 1},
               {"NroRegEstadual", 1, 1},
               {"veic", 0, 1},
               {"infFretamento", 0, 1}
             ]
    end

    test "MDF-e rodo" do
      assert shape(Layout.modal(:mdfe_rodo).root) == [
               {"infANTT", 0, 1},
               {"veicTracao", 1, 1},
               {"veicReboque", 0, 3},
               {"codAgPorto", 0, 1},
               {"lacRodo", 0, :unbounded}
             ]
    end
  end

  describe "keys" do
    test "no key of the layouts is the product of a bad split" do
      cte = all_keys(Layout.cte())
      cte_os = all_keys(Layout.cte_os())
      mdfe = all_keys(Layout.mdfe())

      assert :cte_os in cte_os
      refute :cteos in cte_os
      assert :ch_bpe in cte_os
      assert :cnpj_ipef in all_keys(Layout.modal(:mdfe_rodo))
      assert :v_t_prest in cte
      assert :inf_gtve in cte_os
      assert :ch_mdfe in mdfe
      assert :inf_mdfe in mdfe
      assert :c_mun_carrega in mdfe
    end

    test "every key is unique among its siblings, in every layout" do
      for layout <- [
            Layout.nfe(),
            Layout.cte(),
            Layout.cte_os(),
            Layout.mdfe(),
            Layout.modal(:cte_rodo),
            Layout.modal(:cte_os_rodo),
            Layout.modal(:mdfe_rodo)
          ] do
        assert_unique_siblings(layout.root)
      end
    end
  end

  defp all_keys(%{root: root}), do: all_keys(root)

  defp all_keys(%{kind: :element, key: key, attrs: attrs, content: content}),
    do: [key | Enum.map(attrs, & &1.key)] ++ all_keys(content)

  defp all_keys(%{kind: :foreign, key: key}), do: [key]

  defp all_keys(%{kind: kind, children: children}) when kind in [:sequence, :choice],
    do: Enum.flat_map(children, &all_keys/1)

  defp all_keys(_leaf_or_any_or_nil), do: []

  defp assert_unique_siblings(%{kind: :element} = element) do
    keys = Enum.map(element.attrs, & &1.key) ++ Enum.map(Layout.elements(element), & &1.key)
    distinct = keys |> Enum.uniq() |> length()

    # a choice may repeat a tag in two branches; the same tag has the same key
    names = Enum.map(element.attrs, & &1.name) ++ tags(element)
    assert distinct == names |> Enum.uniq() |> length(), "key collision under #{element.tag}"

    Enum.each(Layout.elements(element), fn
      %{kind: :element} = child -> assert_unique_siblings(child)
      _foreign -> :ok
    end)
  end
end
