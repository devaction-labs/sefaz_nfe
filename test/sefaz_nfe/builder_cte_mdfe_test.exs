defmodule SefazNfe.BuilderCteMdfeTest do
  @moduledoc """
  `Builder.build_cte/2`, `build_cte_os/2`, `build_mdfe/2` and their `parse_*`
  (AD-024, AD-026): the NF-e walker over the CT-e, CT-e OS and MDF-e layouts,
  the generalised access key, and the road modal inside `infModal`.
  """

  use ExUnit.Case, async: true

  alias SefazNfe.AccessKey
  alias SefazNfe.Builder
  alias SefazNfe.CTeMap
  alias SefazNfe.Fixtures
  alias SefazNfe.MDFeMap
  alias SefazNfe.Signer

  @cte_pl System.get_env("SEFAZ_NFE_CTE_PL_PATH")
  @mdfe_pl System.get_env("SEFAZ_NFE_MDFE_PL_PATH")
  @have_xmllint System.find_executable("xmllint") != nil
  @skip_cte if(
              @have_xmllint and is_binary(@cte_pl) and
                File.exists?(Path.join(@cte_pl || "", "cte_v4.00.xsd")),
              do: false,
              else: "SEFAZ_NFE_CTE_PL_PATH or xmllint is not available"
            )
  @skip_mdfe if(
               @have_xmllint and is_binary(@mdfe_pl) and
                 File.exists?(Path.join(@mdfe_pl || "", "mdfe_v3.00.xsd")),
               do: false,
               else: "SEFAZ_NFE_MDFE_PL_PATH or xmllint is not available"
             )

  @cte_ns "http://www.portalfiscal.inf.br/cte"
  @mdfe_ns "http://www.portalfiscal.inf.br/mdfe"

  # What each kind needs: the builder, the reader, the key of the parsed map,
  # the Id prefix and the versao of infXxx, the number and code keys of `ide`.
  @kinds %{
    cte: %{
      build: &Builder.build_cte/2,
      parse: &Builder.parse_cte/2,
      result: :cte,
      fixture: &CTeMap.cte/0,
      prefix: "CTe",
      versao: "4.00",
      number: :n_ct,
      code: :c_ct,
      modal: :rodo,
      ns: @cte_ns
    },
    cte_os: %{
      build: &Builder.build_cte_os/2,
      parse: &Builder.parse_cte_os/2,
      result: :cte_os,
      fixture: &CTeMap.cte_os/0,
      prefix: "CTe",
      versao: "4.00",
      number: :n_ct,
      code: :c_ct,
      modal: :rodo_os,
      ns: @cte_ns
    },
    mdfe: %{
      build: &Builder.build_mdfe/2,
      parse: &Builder.parse_mdfe/2,
      result: :mdfe,
      fixture: &MDFeMap.mdfe/0,
      prefix: "MDFe",
      versao: "3.00",
      number: :n_mdf,
      code: :c_mdf,
      modal: :rodo,
      ns: @mdfe_ns
    }
  }

  # -- Helpers ----------------------------------------------------------------

  defp kind(name), do: Map.fetch!(@kinds, name)

  defp build!(name, map, opts \\ []) do
    assert {:ok, %{xml: xml, access_key: key}} = kind(name).build.(map, opts)
    {xml, key}
  end

  defp errors!(name, map) do
    assert {:error, errors} = kind(name).build.(map, [])
    errors
  end

  defp parse!(name, xml, opts \\ []) do
    assert {:ok, parsed} = kind(name).parse.(xml, opts)
    parsed
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, stringify(v)} end)
  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(integer) when is_integer(integer), do: Integer.to_string(integer)
  defp stringify(other), do: other

  # What `parse` returns for `map`: text leaves, plus what the builder wrote
  # itself (versao, Id, cDV).
  defp expected(name, map, key) do
    spec = kind(name)

    map
    |> stringify()
    |> Map.put(:versao, spec.versao)
    |> Map.put(:id, spec.prefix <> key)
    |> put_in([:ide, :c_dv], String.last(key))
  end

  defp fixtures do
    [
      cte: CTeMap.cte(),
      cte: CTeMap.cte(icms: :icms_sn),
      cte_os: CTeMap.cte_os(),
      mdfe: MDFeMap.mdfe(),
      mdfe: MDFeMap.mdfe(tax_id: :cpf)
    ]
  end

  defp put_modal(name, map, modal) do
    case name do
      :mdfe -> Map.put(map, :inf_modal, modal)
      _cte -> put_in(map, [:inf_cte_norm, :inf_modal], modal)
    end
  end

  defp fetch_modal(:mdfe, map), do: map.inf_modal
  defp fetch_modal(_cte, map), do: map.inf_cte_norm.inf_modal

  # -- The documents ----------------------------------------------------------

  describe "build" do
    test "every fixture builds, with the root, namespace and versao of its document" do
      for {name, map} <- fixtures() do
        spec = kind(name)
        {xml, key} = build!(name, map)

        root = if name == :mdfe, do: "MDFe", else: if(name == :cte, do: "CTe", else: "CTeOS")
        root_versao = if name == :cte_os, do: ~s( versao="4.00"), else: ""
        inf = if name == :mdfe, do: "infMDFe", else: "infCte"

        assert String.starts_with?(
                 xml,
                 ~s(<#{root} xmlns="#{spec.ns}"#{root_versao}><#{inf} Id=")
               )

        assert xml =~ ~s(<#{inf} Id="#{spec.prefix}#{key}" versao="#{spec.versao}">)
        assert String.ends_with?(xml, "</#{root}>")
        refute xml =~ "Signature"
      end
    end

    test ":declaration prepends the XML declaration" do
      {xml, _key} = build!(:mdfe, MDFeMap.mdfe(), declaration: true)
      assert String.starts_with?(xml, ~s(<?xml version="1.0" encoding="UTF-8"?><MDFe))
    end

    test "string keys build the same document as atom keys" do
      for {name, map} <- fixtures() do
        {atoms, _} = build!(name, map)
        {strings, _} = build!(name, stringify_keys(map))
        assert atoms == strings
      end
    end

    test "decimals as Decimal are written with the places of their type" do
      map = put_in(MDFeMap.mdfe(), [:tot, :v_carga], Decimal.new("50000"))
      map = put_in(map, [:tot, :q_carga], Decimal.new("12500.5"))

      {xml, _key} = build!(:mdfe, map)

      assert xml =~ "<vCarga>50000.00</vCarga>"
      assert xml =~ "<qCarga>12500.5000</qCarga>"
    end

    test "a value that needs more places than its type is an error, not rounded" do
      map = put_in(MDFeMap.mdfe(), [:tot, :v_carga], Decimal.new("1.005"))
      assert [{[:tot, :v_carga], {:precision, 2}}] = errors!(:mdfe, map)
    end

    test "layout errors are collected with their paths" do
      map =
        CTeMap.cte()
        |> put_in([:v_prest, :v_t_prest], "12,5")
        |> update_in([:ide], &Map.delete(&1, :x_mun_env))
        |> put_in([:inf_cte_norm, :inf_carga, :inf_q], [])

      assert [
               {[:ide, :x_mun_env], :required},
               {[:inf_cte_norm, :inf_carga, :inf_q], {:occurs, 1, :unbounded, 0}},
               {[:v_prest, :v_t_prest], {:pattern, _}}
             ] = errors!(:cte, map)
    end

    test "a choice is selected by key, the emitter being a CNPJ or a CPF" do
      map = MDFeMap.mdfe()
      emit = Map.delete(map.emit, :cnpj)

      assert [{[:emit], :choice_none}] = errors!(:mdfe, %{map | emit: emit})

      assert [{[:emit], {:choice_many, [:cnpj, :cpf]}}] =
               errors!(:mdfe, %{map | emit: Map.put(map.emit, :cpf, "12345678909")})
    end

    test "a CT-e OS without infModal builds: the modal is optional there" do
      map = CTeMap.cte_os()
      map = update_in(map, [:inf_cte_norm], &Map.delete(&1, :inf_modal))

      assert {:ok, %{xml: xml}} = Builder.build_cte_os(map)
      refute xml =~ "infModal"
    end

    test "something that is not a map is :invalid_type" do
      assert {:error, [{[], :invalid_type}]} = Builder.build_cte("x")
      assert {:error, [{[], :invalid_type}]} = Builder.build_cte_os(nil)
      assert {:error, [{[], :invalid_type}]} = Builder.build_mdfe([])
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {Atom.to_string(k), stringify_keys(v)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  # -- The access key ---------------------------------------------------------

  describe "access key" do
    test "verifies, and its parts are the ones of ide and emit" do
      for {name, map} <- fixtures() do
        spec = kind(name)
        {xml, key} = build!(name, map)

        assert AccessKey.valid?(key)
        assert String.length(key) == 44
        assert binary_part(key, 0, 2) == "29"
        assert binary_part(key, 2, 4) == "2609"
        assert binary_part(key, 20, 2) == stringify(map.ide.mod)
        assert binary_part(key, 22, 3) == "001"

        assert binary_part(key, 25, 9) ==
                 String.pad_leading(stringify(map.ide[spec.number]), 9, "0")

        assert binary_part(key, 34, 1) == "1"
        assert binary_part(key, 35, 8) == map.ide[spec.code]
        assert xml =~ "<cDV>#{String.last(key)}</cDV>"
      end
    end

    test "the emitter is the CNPJ, or the CPF padded to 14 digits" do
      {_xml, cnpj_key} = build!(:mdfe, MDFeMap.mdfe())
      {_xml, cpf_key} = build!(:mdfe, MDFeMap.mdfe(tax_id: :cpf))

      assert binary_part(cnpj_key, 6, 14) == "00000000000191"
      assert binary_part(cpf_key, 6, 14) == "00012345678909"
    end

    test "cCT and cMDF are generated when absent, by the rules of cNF (NT 2019.001)" do
      for {name, map} <- fixtures() do
        spec = kind(name)
        map = update_in(map, [:ide], &Map.delete(&1, spec.code))
        {xml, key} = build!(name, map)
        code = binary_part(key, 35, 8)

        assert code =~ ~r/^[0-9]{8}$/
        assert code != String.pad_leading(stringify(map.ide[spec.number]), 8, "0")
        assert xml =~ "<#{if name == :mdfe, do: "cMDF", else: "cCT"}>#{code}</"

        assert parse!(name, xml)[spec.result].ide[spec.code] == code
      end
    end

    test "the code is never the document number" do
      map = update_in(CTeMap.cte(), [:ide], &%{&1 | c_ct: "00001234"})
      assert [{[:ide, :c_ct], :equals_n_nf}] = errors!(:cte, map)

      map = update_in(MDFeMap.mdfe(), [:ide], &%{&1 | c_mdf: "00000055"})
      assert [{[:ide, :c_mdf], :equals_n_nf}] = errors!(:mdfe, map)
    end

    test "Id and cDV are generated, and a wrong one given is reported" do
      {_xml, key} = build!(:cte, CTeMap.cte())
      {_xml, os_key} = build!(:cte_os, CTeMap.cte_os())
      {_xml, mdfe_key} = build!(:mdfe, MDFeMap.mdfe())

      map = CTeMap.cte() |> Map.put(:id, "CTe" <> key) |> put_in([:ide, :c_dv], String.last(key))
      assert {:ok, %{access_key: ^key}} = Builder.build_cte(map)

      assert [{[:id], {:mismatch, _}}] =
               errors!(:cte, Map.put(CTeMap.cte(), :id, "CTe" <> String.duplicate("1", 44)))

      assert [{[:ide, :c_dv], {:mismatch, expected}}] =
               errors!(:cte_os, put_in(CTeMap.cte_os(), [:ide, :c_dv], "0"))

      assert expected == String.last(os_key)

      # The prefix is the document's: "CTe" is neither the key's nor the layout's.
      assert [{[:id], {:mismatch, "MDFe" <> ^mdfe_key}}, {[:id], {:pattern, _}}] =
               errors!(:mdfe, Map.put(MDFeMap.mdfe(), :id, "CTe" <> mdfe_key))
    end

    test "AccessKey.build/1 takes models 57, 67 and 58 with the same 44 digits" do
      fields = %{
        c_uf: 29,
        dh_emi: "2026-09-07T10:00:00-03:00",
        cnpj: "00000000000191",
        serie: 1,
        n_nf: 1234,
        tp_emis: 1,
        c_nf: "12345679"
      }

      for model <- [57, 67, 58] do
        assert {:ok, key} = AccessKey.build(Map.put(fields, :mod, model))
        assert AccessKey.valid?(key)
        assert binary_part(key, 20, 2) == Integer.to_string(model)
      end
    end
  end

  # -- The modal --------------------------------------------------------------

  describe "modal" do
    test "the modal key picks the layout and is written inside infModal" do
      {cte, _} = build!(:cte, CTeMap.cte())
      {os, _} = build!(:cte_os, CTeMap.cte_os())
      {mdfe, _} = build!(:mdfe, MDFeMap.mdfe())

      assert cte =~
               ~s(<infModal versaoModal="4.00"><rodo><RNTRC>12345678</RNTRC></rodo></infModal>)

      assert os =~ ~s(<infModal versaoModal="4.00"><rodoOS><TAF>123456789012</TAF><veic>)
      assert mdfe =~ ~s(<infModal versaoModal="3.00"><rodo><infANTT><RNTRC>12345678</RNTRC>)
    end

    test "the modal is walked like the rest: order and lists come from its layout" do
      {xml, _key} = build!(:mdfe, MDFeMap.mdfe())

      assert xml =~ "<veicTracao><cInt>T01</cInt><placa>ABC1D23</placa>"

      assert xml =~
               "<condutor><xNome>JOAO DA SILVA</xNome><CPF>12345678909</CPF></condutor><condutor>"

      assert xml =~ "</veicTracao><veicReboque>"
      assert xml =~ "<lacRodo><nLacre>RODO-001</nLacre></lacRodo></rodo></infModal>"
    end

    test "a modal key given as a string is the same modal" do
      for name <- [:cte, :cte_os, :mdfe] do
        map = kind(name).fixture.()
        modal = fetch_modal(name, map)
        key = Atom.to_string(kind(name).modal)

        string_modal =
          modal
          |> Map.delete(kind(name).modal)
          |> Map.put("versao_modal", modal.versao_modal)
          |> Map.delete(:versao_modal)
          |> Map.put(key, stringify_keys(Map.fetch!(modal, kind(name).modal)))

        assert build!(name, map) == build!(name, put_modal(name, map, string_modal))
      end
    end

    test "a modal with no layout is {:unsupported_modal, key}" do
      for {name, modal_key} <- [
            cte: :aereo,
            cte: :aquav,
            cte: :ferrov,
            cte: :duto,
            cte: :multimodal,
            cte_os: :aereo,
            mdfe: :ferrov,
            mdfe: :aquav
          ] do
        map = kind(name).fixture.()
        modal = %{modal_key => %{}, versao_modal: fetch_modal(name, map).versao_modal}

        assert errors!(name, put_modal(name, map, modal)) ==
                 [
                   {modal_path(name), :choice_none},
                   {modal_path(name) ++ [modal_key], {:unsupported_modal, modal_key}}
                 ]
      end
    end

    test "the road modal of the other document is not this document's" do
      map =
        put_modal(:cte, CTeMap.cte(), %{versao_modal: "4.00", rodo_os: %{taf: "123456789012"}})

      assert [
               {[:inf_cte_norm, :inf_modal], :choice_none},
               {[:inf_cte_norm, :inf_modal, :rodo_os], {:unsupported_modal, :rodo_os}}
             ] = errors!(:cte, map)

      map =
        put_modal(:cte_os, CTeMap.cte_os(), %{versao_modal: "4.00", rodo: %{rntrc: "12345678"}})

      assert [
               {[:inf_cte_norm, :inf_modal], :choice_none},
               {[:inf_cte_norm, :inf_modal, :rodo], {:unsupported_modal, :rodo}}
             ] = errors!(:cte_os, map)
    end

    test "an unknown key in infModal is :unknown_key, not a modal" do
      map = put_modal(:mdfe, MDFeMap.mdfe(), %{versao_modal: "3.00", teleport: %{}})

      assert [
               {[:inf_modal], :choice_none},
               {[:inf_modal, :teleport], :unknown_key}
             ] = errors!(:mdfe, map)
    end

    test "no modal, or two, are errors of the choice" do
      map = put_modal(:mdfe, MDFeMap.mdfe(), %{versao_modal: "3.00"})
      assert [{[:inf_modal], :choice_none}] = errors!(:mdfe, map)

      map = put_modal(:cte, CTeMap.cte(), %{versao_modal: "4.00"})
      assert [{[:inf_cte_norm, :inf_modal], :choice_none}] = errors!(:cte, map)
    end

    test "a missing required field of the modal is reported with its path" do
      map = update_in(CTeMap.cte(), [:inf_cte_norm, :inf_modal, :rodo], &Map.delete(&1, :rntrc))
      assert [{[:inf_cte_norm, :inf_modal, :rodo, :rntrc], :required}] = errors!(:cte, map)

      map = update_in(MDFeMap.mdfe(), [:inf_modal, :rodo], &Map.delete(&1, :veic_tracao))
      assert [{[:inf_modal, :rodo, :veic_tracao], :required}] = errors!(:mdfe, map)

      map = put_in(MDFeMap.mdfe(), [:inf_modal, :rodo, :veic_tracao, :condutor], [])

      assert [{[:inf_modal, :rodo, :veic_tracao, :condutor], {:occurs, 1, 10, 0}}] =
               errors!(:mdfe, map)

      map =
        update_in(CTeMap.cte_os(), [:inf_cte_norm, :inf_modal, :rodo_os], &Map.delete(&1, :taf))

      assert [{[:inf_cte_norm, :inf_modal, :rodo_os], :choice_none}] = errors!(:cte_os, map)
    end

    test "a bad value in the modal, and a missing versao_modal, are facets of their layout" do
      map = put_in(CTeMap.cte(), [:inf_cte_norm, :inf_modal, :rodo, :rntrc], "123")
      assert [{[:inf_cte_norm, :inf_modal, :rodo, :rntrc], {:pattern, _}}] = errors!(:cte, map)

      map = update_in(MDFeMap.mdfe(), [:inf_modal], &Map.delete(&1, :versao_modal))
      assert [{[:inf_modal, :versao_modal], :required}] = errors!(:mdfe, map)

      map = put_in(MDFeMap.mdfe(), [:inf_modal, :versao_modal], "4.00")
      assert [{[:inf_modal, :versao_modal], {:pattern, _}}] = errors!(:mdfe, map)
    end
  end

  defp modal_path(:mdfe), do: [:inf_modal]
  defp modal_path(_cte), do: [:inf_cte_norm, :inf_modal]

  # -- Reading back -----------------------------------------------------------

  describe "parse" do
    test "round trip: parse(build(m)) is m, and build(parse(build(m))) is build(m)" do
      for {name, map} <- fixtures() do
        spec = kind(name)
        {xml, key} = build!(name, map)
        parsed = parse!(name, xml)

        assert parsed[spec.result] == expected(name, map, key)
        assert parsed.supl == nil
        assert parsed.protocol == nil
        assert parsed.signed? == false
        assert {xml, key} == build!(name, parsed[spec.result])
      end
    end

    test "the modal comes back under its key, versao_modal included" do
      parsed = parse!(:cte, elem(build!(:cte, CTeMap.cte()), 0)).cte
      assert parsed.inf_cte_norm.inf_modal == %{versao_modal: "4.00", rodo: %{rntrc: "12345678"}}

      parsed = parse!(:cte_os, elem(build!(:cte_os, CTeMap.cte_os()), 0)).cte_os

      assert %{versao_modal: "4.00", rodo_os: %{taf: "123456789012", veic: %{placa: "ABC1D23"}}} =
               parsed.inf_cte_norm.inf_modal

      parsed = parse!(:mdfe, elem(build!(:mdfe, MDFeMap.mdfe()), 0)).mdfe
      assert %{versao_modal: "3.00", rodo: %{veic_tracao: %{condutor: [_, _]}}} = parsed.inf_modal
    end

    test "lists are lists also with one occurrence" do
      map = update_in(MDFeMap.mdfe(), [:ide], &%{&1 | inf_mun_carrega: [hd(&1.inf_mun_carrega)]})
      parsed = parse!(:mdfe, elem(build!(:mdfe, map), 0)).mdfe

      assert [%{c_mun_carrega: "2927408"}] = parsed.ide.inf_mun_carrega
    end

    test "decimals: true turns TDec leaves into Decimal" do
      parsed = parse!(:mdfe, elem(build!(:mdfe, MDFeMap.mdfe()), 0), decimals: true).mdfe

      assert Decimal.equal?(parsed.tot.v_carga, Decimal.new("50000.00"))
      assert Decimal.equal?(parsed.tot.q_carga, Decimal.new("12500"))
    end

    test "a protocol document is read with its protCTe / protMDFe" do
      for {name, tag, ch} <- [
            {:cte, "cteProc", :ch_cte},
            {:cte_os, "cteOSProc", :ch_cte},
            {:mdfe, "mdfeProc", :ch_mdfe}
          ] do
        spec = kind(name)
        {xml, key} = build!(name, spec.fixture.())
        {:ok, signed} = Signer.sign(xml, Fixtures.cert(), inf_tag(name), root_tag(name))

        prot_tag = if name == :mdfe, do: "protMDFe", else: "protCTe"
        ch_tag = if name == :mdfe, do: "chMDFe", else: "chCTe"

        proc =
          ~s(<#{tag} xmlns="#{spec.ns}" versao="#{spec.versao}">) <>
            signed <>
            ~s(<#{prot_tag} versao="#{spec.versao}"><infProt Id="ID123"><tpAmb>2</tpAmb>) <>
            ~s(<verAplic>SVRS</verAplic><#{ch_tag}>#{key}</#{ch_tag}>) <>
            ~s(<dhRecbto>2026-09-07T10:00:05-03:00</dhRecbto><nProt>123456789012345</nProt>) <>
            ~s(<digVal>abc=</digVal><cStat>100</cStat><xMotivo>Autorizado</xMotivo>) <>
            ~s(</infProt></#{prot_tag}></#{tag}>)

        parsed = parse!(name, proc)

        assert parsed.signed?
        assert parsed[spec.result] == expected(name, spec.fixture.(), key)

        assert %{
                 versao: _,
                 id: "ID123",
                 tp_amb: "2",
                 c_stat: "100",
                 n_prot: "123456789012345",
                 x_motivo: "Autorizado"
               } = parsed.protocol

        assert parsed.protocol[ch] == key
      end
    end

    test "the supplementary info (QR code) is returned apart" do
      {xml, key} = build!(:cte, CTeMap.cte())
      qr = "https://dfe-portal.svrs.rs.gov.br/cte/qrCode?chCTe=#{key}&amp;tpAmb=2"

      xml =
        String.replace(
          xml,
          "</infCte>",
          "</infCte><infCTeSupl><qrCodCTe>#{qr}</qrCodCTe></infCTeSupl>"
        )

      assert parse!(:cte, xml).supl == %{qr_cod_cte: String.replace(qr, "&amp;", "&")}
    end

    test "a root of another document is :unexpected_root" do
      {cte, _} = build!(:cte, CTeMap.cte())
      {os, _} = build!(:cte_os, CTeMap.cte_os())
      {mdfe, _} = build!(:mdfe, MDFeMap.mdfe())

      assert {:error, {:unexpected_root, "CTeOS"}} = Builder.parse_cte(os)
      assert {:error, {:unexpected_root, "CTe"}} = Builder.parse_cte_os(cte)
      assert {:error, {:unexpected_root, "MDFe"}} = Builder.parse_cte(mdfe)
      assert {:error, {:unexpected_root, "CTe"}} = Builder.parse_mdfe(cte)
      assert {:error, {:unexpected_root, "CTe"}} = Builder.parse_nfe(cte)
    end

    test "a modal this library has no layout for is :unsupported_modal, or kept when not strict" do
      {xml, _key} = build!(:mdfe, MDFeMap.mdfe())
      aereo = xml |> String.replace("<rodo>", "<aereo>") |> String.replace("</rodo>", "</aereo>")

      assert {:error, {:unsupported_modal, "aereo"}} = Builder.parse_mdfe(aereo)

      assert {:ok, %{mdfe: %{inf_modal: modal}}} = Builder.parse_mdfe(aereo, strict: false)
      assert Map.has_key?(modal.__unknown__, "aereo")
    end

    test "a second modal element is a duplicate" do
      {xml, _key} = build!(:mdfe, MDFeMap.mdfe())
      [_, rodo] = Regex.run(~r{(<rodo>.*</rodo>)}s, xml)
      xml = String.replace(xml, "</infModal>", rodo <> "</infModal>")

      assert {:error, {:duplicate_element, [:inf_mdfe, :inf_modal, :rodo]}} =
               Builder.parse_mdfe(xml)
    end
  end

  defp inf_tag(:mdfe), do: "infMDFe"
  defp inf_tag(_cte), do: "infCte"

  defp root_tag(:mdfe), do: "MDFe"
  defp root_tag(:cte), do: "CTe"
  defp root_tag(:cte_os), do: "CTeOS"

  # -- The real schemas -------------------------------------------------------
  #
  # The modal sits in an `xs:any` with `processContents="skip"`, so xmllint does
  # not look inside `infModal`: the modal fragment is validated on its own
  # against the modal schema.

  @xsd %{
    cte: {:cte, "cte_v4.00.xsd", "cteModalRodoviario_v4.00.xsd"},
    cte_os: {:cte, "cteOS_v4.00.xsd", "cteModalRodoviarioOS_v4.00.xsd"},
    mdfe: {:mdfe, "mdfe_v3.00.xsd", "mdfeModalRodoviario_v3.00.xsd"}
  }

  describe "against the real PL schemas (xmllint)" do
    @tag skip: @skip_cte
    test "CT-e, with ICMS 00 and with ICMSSN, signed" do
      assert validate(:cte, CTeMap.cte()) == :ok
      assert validate(:cte, CTeMap.cte(icms: :icms_sn)) == :ok
    end

    @tag skip: @skip_cte
    test "CT-e OS, signed" do
      assert validate(:cte_os, CTeMap.cte_os()) == :ok
    end

    @tag skip: @skip_mdfe
    test "MDF-e, emitter CNPJ and CPF, signed" do
      assert validate(:mdfe, MDFeMap.mdfe()) == :ok
      assert validate(:mdfe, MDFeMap.mdfe(tax_id: :cpf)) == :ok
    end

    @tag skip: @skip_mdfe
    test "xmllint does reject a broken document (the checks above are not vacuous)" do
      {xml, _key} = build!(:mdfe, MDFeMap.mdfe())
      broken = String.replace(xml, "<cUF>29</cUF>", "<cUF>99</cUF>")

      assert validate_xml(:mdfe, broken) =~ "cUF"
    end

    @tag skip: @skip_mdfe
    test "the modal fragment is checked by xmllint too, and a bad one is rejected" do
      {xml, _key} = build!(:mdfe, MDFeMap.mdfe())
      assert validate_modal(:mdfe, xml) == :ok

      assert validate_modal(:mdfe, String.replace(xml, "<tara>9000</tara>", "<tara>x</tara>")) =~
               "tara"
    end
  end

  defp pl(name) do
    case elem(Map.fetch!(@xsd, name), 0) do
      :cte -> @cte_pl
      :mdfe -> @mdfe_pl
    end
  end

  # Signs with the test certificate, which also shows Signer takes the output.
  defp validate(name, map) do
    {xml, _key} = build!(name, map)
    {:ok, signed} = Signer.sign(xml, Fixtures.cert(), inf_tag(name), root_tag(name))

    case validate_xml(name, signed) do
      :ok -> validate_modal(name, xml)
      other -> other
    end
  end

  defp validate_xml(name, xml) do
    {_pl, schema, _modal} = Map.fetch!(@xsd, name)
    xmllint(pl(name), schema, xml)
  end

  # The content of `infModal`, given the namespace the document gives it.
  defp validate_modal(name, xml) do
    {_pl, _schema, modal_schema} = Map.fetch!(@xsd, name)
    [_, fragment] = Regex.run(~r{<infModal[^>]*>(.*)</infModal>}s, xml)
    ns = kind(name).ns
    fragment = String.replace(fragment, ~r/^<(\w+)/, ~s(<\\1 xmlns="#{ns}"), global: false)

    xmllint(pl(name), modal_schema, fragment)
  end

  defp xmllint(pl, schema, xml) do
    file = Path.join(System.tmp_dir!(), "cte_mdfe_#{System.unique_integer([:positive])}.xml")
    File.write!(file, xml)

    try do
      case System.cmd("xmllint", ["--noout", "--schema", schema, file],
             cd: pl,
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
