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

  @keys [
    {"vICMSUFDest", "v_icms_uf_dest"},
    {"CNPJ", "cnpj"},
    {"ICMS00", "icms00"},
    {"ICMSSN102", "icmssn102"},
    {"infNFeSupl", "inf_nfe_supl"},
    {"infNFe", "inf_nfe"},
    {"chNFe", "ch_nfe"},
    {"xPed", "x_ped"},
    {"nItemPed", "n_item_ped"},
    {"IBSCBS", "ibscbs"},
    {"gIBSCBS", "g_ibscbs"},
    {"vIBSUF", "v_ibsuf"},
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

  describe "generation errors" do
    @describetag :tmp_dir

    test "an unsupported idiom raises instead of being dropped", %{tmp_dir: tmp} do
      write_schema(tmp, """
      <xs:element name="NFe" type="TNFe"/>
      <xs:complexType name="TNFe"><xs:sequence><xs:any/></xs:sequence></xs:complexType>
      """)

      assert_raise ArgumentError, ~r/unsupported <any>/, fn -> Generator.generate(tmp) end
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

  defp write_schema(dir, body) do
    File.write!(Path.join(dir, "nfe_v4.00.xsd"), """
    <xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" targetNamespace="urn:t" xmlns="urn:t">
    #{body}</xs:schema>
    """)
  end
end
