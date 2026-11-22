defmodule SefazNfe.Layout.GeneratorTest do
  @moduledoc """
  The XSDs are not in this repository (AD-015). Point `SEFAZ_NFE_PL_PATH` at an
  unpacked PL (for example `PL_010_V1.30`) to run the tests that regenerate the
  layout; they are skipped otherwise. The key tests need no XSD.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Sefaz.GenLayout
  alias SefazNfe.Layout.Generator

  @pl System.get_env("SEFAZ_NFE_PL_PATH")
  @have_pl is_binary(@pl) and File.exists?(Path.join(@pl, "leiauteNFe_v4.00.xsd"))

  @cte_pl System.get_env("SEFAZ_NFE_CTE_PL_PATH")
  @have_cte is_binary(@cte_pl) and File.exists?(Path.join(@cte_pl, "cte_v4.00.xsd"))
  @mdfe_pl System.get_env("SEFAZ_NFE_MDFE_PL_PATH")
  @have_mdfe is_binary(@mdfe_pl) and File.exists?(Path.join(@mdfe_pl, "mdfe_v3.00.xsd"))

  @keys [
    {"CTeOS", "cte_os"},
    {"rodoOS", "rodo_os"},
    {"MDFe", "mdfe"},
    {"chMDFe", "ch_mdfe"},
    {"chCTe", "ch_cte"},
    {"chBPe", "ch_bpe"},
    {"infGTVe", "inf_gtve"},
    {"infDCe", "inf_dce"},
    {"CNPJIPEF", "cnpj_ipef"},
    {"UFIni", "uf_ini"},
    {"cMunCarrega", "c_mun_carrega"},
    {"vTPrest", "v_t_prest"},
    {"qCarga", "q_carga"},
    {"vBCSTRet", "v_bc_st_ret"},
    {"ICMSOutraUF", "icms_outra_uf"},
    {"ICMSSN", "icms_sn"},
    {"RNTRC", "rntrc"},
    {"CIOT", "ciot"},
    {"vICMSUFDest", "v_icms_uf_dest"},
    {"CNPJ", "cnpj"},
    {"ICMS00", "icms00"},
    {"ICMSSN102", "icms_sn102"},
    {"ICMSST", "icms_st"},
    {"ISTot", "is_tot"},
    {"ISUF", "isuf"},
    {"ISUFEmit", "isuf_emit"},
    {"IEST", "ie_st"},
    {"UFST", "uf_st"},
    {"CSOSN", "csosn"},
    {"refNFe", "ref_nfe"},
    {"refDFe", "ref_dfe"},
    {"cMunFGIBS", "c_mun_fg_ibs"},
    {"tpALCZFMCBS", "tp_alc_zfm_cbs"},
    {"COFINSNT", "cofins_nt"},
    {"xNEmp", "x_n_emp"},
    {"infNFeSupl", "inf_nfe_supl"},
    {"infNFe", "inf_nfe"},
    {"chNFe", "ch_nfe"},
    {"xPed", "x_ped"},
    {"nItemPed", "n_item_ped"},
    {"IBSCBS", "ibs_cbs"},
    {"gIBSCBS", "g_ibs_cbs"},
    {"vIBSUF", "v_ibs_uf"},
    {"vBCSTDest", "v_bc_st_dest"},
    {"vBCFCPUFDest", "v_bc_fcp_uf_dest"},
    {"ISSQNtot", "issqn_tot"},
    {"ICMSTot", "icms_tot"},
    {"CNPJBasePSP", "cnpj_base_psp"},
    {"cEANTrib", "c_ean_trib"},
    {"UFCons", "uf_cons"},
    {"vICMSSubstituto", "v_icms_substituto"},
    {"pICMSInterPart", "p_icms_inter_part"},
    {"nItem", "n_item"},
    {"Id", "id"},
    {"cUF", "c_uf"},
    {"det", "det"}
  ]

  describe "snake_case/1" do
    for {name, key} <- @keys do
      test "#{name} is #{key}" do
        assert Generator.snake_case(unquote(name)) == unquote(key)
      end
    end
  end

  describe "collisions/1" do
    test "different names that share a key are reported" do
      assert {:error, [{"v_foo", ["vFoo", "VFoo"]}]} =
               Generator.collisions(["vFoo", "VFoo", "other"])
    end

    test "an attribute and an element with one key collide" do
      assert {:error, [{"id", ["Id", "@id"]}]} = Generator.collisions(["Id", "@id"])
    end

    test "the same name twice (the two branches of a choice) is not a collision" do
      assert :ok = Generator.collisions(["IPI", "IPI", "ICMS"])
    end
  end

  describe "against the XSD package" do
    @describetag skip: not @have_pl && "SEFAZ_NFE_PL_PATH does not point at a PL directory"

    @tag :tmp_dir
    test "generation is byte-stable and equals the committed layout", %{tmp_dir: tmp} do
      first = Path.join(tmp, "a.etf")
      second = Path.join(tmp, "b.etf")

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      GenLayout.run([@pl, "--out", first])
      GenLayout.run([@pl, "--out", second])

      assert File.read!(first) == File.read!(second)
      assert File.read!(first) == File.read!("priv/layouts/nfe_4.00.etf")
    end

    test "the committed hashes match the XSDs that were read" do
      layout = Generator.generate(@pl)

      for %{file: file, sha256: sha} <- layout.sources do
        actual =
          :crypto.hash(:sha256, File.read!(Path.join(@pl, file))) |> Base.encode16(case: :lower)

        assert actual == sha
      end

      assert layout == SefazNfe.Layout.nfe()
    end
  end

  describe "against the CT-e and MDF-e packages" do
    @describetag :tmp_dir

    # {env var is usable, PL path, output file, mix options}
    @targets [
      {@have_cte, @cte_pl, "cte_4.00", ~w(--entry cte_v4.00.xsd --root TCTe)},
      {@have_cte, @cte_pl, "cte_os_4.00", ~w(--entry cteOS_v4.00.xsd --root TCTeOS)},
      {@have_cte, @cte_pl, "cte_modal_rodoviario_4.00",
       ~w(--entry cteModalRodoviario_v4.00.xsd --element rodo)},
      {@have_cte, @cte_pl, "cte_os_modal_rodoviario_4.00",
       ~w(--entry cteModalRodoviarioOS_v4.00.xsd --element rodoOS)},
      {@have_mdfe, @mdfe_pl, "mdfe_3.00", ~w(--entry mdfe_v3.00.xsd --root TMDFe)},
      {@have_mdfe, @mdfe_pl, "mdfe_modal_rodoviario_3.00",
       ~w(--entry mdfeModalRodoviario_v3.00.xsd --element rodo)}
    ]

    for {have, pl, name, options} <- @targets do
      @tag skip: not have && "SEFAZ_NFE_CTE_PL_PATH / SEFAZ_NFE_MDFE_PL_PATH not set"
      test "#{name}: generation is byte-stable and equals the committed layout", %{tmp_dir: tmp} do
        first = Path.join(tmp, "a.etf")
        second = Path.join(tmp, "b.etf")

        Mix.shell(Mix.Shell.Process)
        on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

        GenLayout.run([unquote(pl)] ++ unquote(options) ++ ["--out", first])
        GenLayout.run([unquote(pl)] ++ unquote(options) ++ ["--out", second])

        assert File.read!(first) == File.read!(second)
        assert File.read!(first) == File.read!("priv/layouts/#{unquote(name)}.etf")
      end
    end
  end

  describe "generation errors" do
    @describetag :tmp_dir

    test "an unsupported idiom raises instead of being dropped", %{tmp_dir: tmp} do
      write_schema(tmp, """
      <xs:element name="NFe" type="TNFe"/>
      <xs:complexType name="TNFe"><xs:group ref="g"/></xs:complexType>
      """)

      assert_raise ArgumentError, ~r/unsupported <group>/, fn -> Generator.generate(tmp) end
    end

    test "sibling key collisions abort generation", %{tmp_dir: tmp} do
      write_schema(tmp, """
      <xs:element name="NFe" type="TNFe"/>
      <xs:complexType name="TNFe"><xs:sequence>
        <xs:element name="vFoo" type="xs:string"/>
        <xs:element name="VFoo" type="xs:string"/>
      </xs:sequence></xs:complexType>
      """)

      assert_raise ArgumentError, ~r/key collision/, fn -> Generator.generate(tmp) end
    end

    test "a DTD in an XSD is refused", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "nfe_v4.00.xsd"), """
      <!DOCTYPE x [<!ENTITY e "boom">]>
      <xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"/>
      """)

      assert_raise ArgumentError, ~r/dtd_forbidden/, fn -> Generator.generate(tmp) end
    end

    test "a tiny schema covers occurrence, choice, attributes and restriction", %{tmp_dir: tmp} do
      write_schema(tmp, """
      <xs:element name="NFe" type="TNFe"/>
      <xs:simpleType name="TNum"><xs:restriction base="xs:string">
        <xs:pattern value="[0-9]+"/><xs:maxLength value="3"/></xs:restriction></xs:simpleType>
      <xs:complexType name="TNFe"><xs:sequence>
        <xs:element name="a" type="TNum" maxOccurs="unbounded"/>
        <xs:choice minOccurs="0">
          <xs:element name="bX" type="xs:string"/>
          <xs:sequence><xs:element name="cY" type="xs:string"/></xs:sequence>
        </xs:choice>
      </xs:sequence><xs:attribute name="versao" type="TNum" use="required" fixed="1"/></xs:complexType>
      """)

      %{root: root} = Generator.generate(tmp)

      assert [%{name: "versao", use: :required, fixed: "1"}] = root.attrs
      assert %{kind: :sequence, children: [a, choice]} = root.content
      assert %{tag: "a", max: :unbounded, content: %{name: "TNum", max_length: 3}} = a
      assert %{kind: :choice, min: 0, children: [%{key: :b_x}, %{kind: :sequence}]} = choice
    end
  end

  describe "xs:any and untyped elements" do
    @describetag :tmp_dir

    test "xs:any becomes an :any node with its namespace and processContents", %{tmp_dir: tmp} do
      write_schema(tmp, """
      <xs:element name="NFe" type="TNFe"/>
      <xs:complexType name="TNFe"><xs:sequence>
        <xs:element name="pre" type="xs:string"/>
        <xs:element name="infModal"><xs:complexType><xs:sequence>
          <xs:any processContents="skip"/>
        </xs:sequence><xs:attribute name="versaoModal" type="xs:string" use="required"/>
        </xs:complexType></xs:element>
        <xs:any namespace="##other" minOccurs="0" maxOccurs="unbounded"/>
      </xs:sequence></xs:complexType>
      """)

      %{root: root} = Generator.generate(tmp)
      assert %{kind: :sequence, children: [_pre, modal, any]} = root.content

      assert %{content: %{kind: :sequence, children: [inner]}, attrs: [%{key: :versao_modal}]} =
               modal

      assert inner == %{
               kind: :any,
               namespace: "##any",
               process_contents: :skip,
               min: 1,
               max: 1
             }

      assert %{
               kind: :any,
               namespace: "##other",
               process_contents: :strict,
               min: 0,
               max: :unbounded
             } = any

      assert Enum.map(SefazNfe.Layout.elements(root), & &1.tag) == ["pre", "infModal"]
    end

    test "an element with no type at all is an any_type leaf", %{tmp_dir: tmp} do
      write_schema(tmp, """
      <xs:element name="NFe" type="TNFe"/>
      <xs:complexType name="TNFe"><xs:sequence>
        <xs:element name="ref" minOccurs="0" maxOccurs="unbounded">
          <xs:annotation><xs:documentation>only docs</xs:documentation></xs:annotation>
        </xs:element>
      </xs:sequence></xs:complexType>
      """)

      assert %{root: %{content: %{children: [ref]}}} = Generator.generate(tmp)
      assert %{tag: "ref", min: 0, max: :unbounded, content: %{base: :any_type, name: nil}} = ref
    end

    test "--element compiles a global element with an anonymous type", %{tmp_dir: tmp} do
      write_schema(tmp, """
      <xs:element name="rodo"><xs:complexType><xs:sequence>
        <xs:element name="RNTRC" type="xs:string"/>
      </xs:sequence></xs:complexType></xs:element>
      """)

      layout = Generator.generate(tmp, element: "rodo")

      assert %{root_type: nil, root_element: "rodo", namespace: "urn:t"} = layout
      assert %{tag: "rodo", content: %{children: [%{key: :rntrc}]}} = layout.root

      assert_raise ArgumentError, ~r/no global element nope/, fn ->
        Generator.generate(tmp, element: "nope")
      end
    end
  end

  defp write_schema(dir, body) do
    File.write!(Path.join(dir, "nfe_v4.00.xsd"), """
    <xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" targetNamespace="urn:t" xmlns="urn:t">
    #{body}</xs:schema>
    """)
  end
end
