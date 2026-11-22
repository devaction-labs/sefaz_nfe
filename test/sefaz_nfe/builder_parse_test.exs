defmodule SefazNfe.BuilderParseTest do
  @moduledoc """
  `Builder.parse_nfe/2`: the XML read back into the builder's own map. The
  property is `parse(build(m)) == m` once the leaves are text, and the stronger
  `build(parse(build(m))) == build(m)`.
  """

  use ExUnit.Case, async: true

  alias SefazNfe.Builder
  alias SefazNfe.Fixtures
  alias SefazNfe.NFeBuilder
  alias SefazNfe.NFeMap
  alias SefazNfe.Proc
  alias SefazNfe.Signer

  defp d(string), do: Decimal.new(string)

  defp key(model), do: NFeBuilder.build(c_nf: 12_345_678, model: model).access_key
  defp document(model, crt), do: NFeMap.document(model, crt, key(model))
  defp simple, do: document(55, 3)

  defp build!(map, opts \\ []) do
    assert {:ok, %{xml: xml}} = Builder.build_nfe(map, opts)
    xml
  end

  defp parse!(xml, opts \\ []) do
    assert {:ok, parsed} = Builder.parse_nfe(xml, opts)
    parsed
  end

  defp update_item(doc, fun), do: %{doc | det: [fun.(hd(doc.det))]}

  # What parse returns for `m`: the same tree with text leaves, the versao and
  # the nItem the builder wrote.
  defp normalise(map) do
    map
    |> Map.put(:versao, "4.00")
    |> Map.update!(:det, fn items ->
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {item, n} -> item |> text() |> Map.put(:n_item, Integer.to_string(n)) end)
    end)
    |> Map.new(fn
      {:det, items} -> {:det, items}
      {key, value} -> {key, text(value)}
    end)
  end

  defp text(%Decimal{} = decimal), do: {:decimal, decimal}
  defp text(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, text(v)} end)
  defp text(list) when is_list(list), do: Enum.map(list, &text/1)
  defp text(integer) when is_integer(integer), do: Integer.to_string(integer)
  defp text(other), do: other

  # Decimals are text with the places of their type, so they are compared by
  # value; everything else by equality.
  defp assert_same(expected, actual, path \\ [])

  defp assert_same({:decimal, decimal}, actual, path) do
    assert is_binary(actual), "#{inspect(path)}: #{inspect(actual)} is not text"
    assert Decimal.equal?(decimal, Decimal.new(actual)), "#{inspect(path)}: #{actual}"
  end

  defp assert_same(expected, actual, path) when is_map(expected) do
    assert is_map(actual), "#{inspect(path)}: #{inspect(actual)} is not a map"
    assert Enum.sort(Map.keys(actual)) == Enum.sort(Map.keys(expected)), inspect(path)
    for {key, value} <- expected, do: assert_same(value, Map.fetch!(actual, key), path ++ [key])
  end

  defp assert_same(expected, actual, path) when is_list(expected) do
    assert is_list(actual) and length(actual) == length(expected), inspect(path)

    expected
    |> Enum.zip(actual)
    |> Enum.with_index()
    |> Enum.each(fn {{e, a}, i} -> assert_same(e, a, path ++ [i]) end)
  end

  defp assert_same(expected, actual, path), do: assert(actual == expected, inspect(path))

  defp assert_round_trip(map) do
    xml = build!(map)
    parsed = parse!(xml)

    assert_same(normalise(map), parsed.nfe)
    assert build!(parsed.nfe) == xml
    assert parsed.supl == nil
    assert parsed.protocol == nil
    assert parsed.signed? == false
  end

  # -- Round trip -------------------------------------------------------------

  describe "round trip" do
    test "every NFeMap fixture" do
      for model <- [55, 65], crt <- [1, 3] do
        assert_round_trip(document(model, crt))
      end
    end

    test "with the key, cNF and cDV generated, they come back in the map" do
      map = simple() |> Map.delete(:id) |> update_in([:ide], &Map.drop(&1, [:c_nf, :c_dv]))

      assert {:ok, %{xml: xml, access_key: key}} = Builder.build_nfe(map)
      parsed = parse!(xml).nfe

      assert parsed.id == "NFe" <> key
      assert parsed.ide.c_dv == String.last(key)
      assert parsed.ide.c_nf == binary_part(key, 35, 8)
      assert build!(parsed) == xml
    end

    test "the leaves are text, exactly as written" do
      parsed = parse!(build!(simple())).nfe

      assert parsed.versao == "4.00"
      assert parsed.ide.c_uf == "35"
      assert parsed.ide.dh_emi == "2026-09-07T10:00:00-03:00"
      assert [%{n_item: "1", prod: %{v_prod: "100.00", q_com: "1.0000"}}] = parsed.det
      assert parsed.det |> hd() |> get_in([:imposto, :icms, :icms00, :p_icms]) == "18.00"
    end

    test "entities and accents survive" do
      map = update_item(simple(), &put_in(&1, [:prod, :x_prod], "CAFÉ & <AÇÚCAR> \"1\" 'a'"))

      assert hd(parse!(build!(map)).nfe.det).prod.x_prod == "CAFÉ & <AÇÚCAR> \"1\" 'a'"
      assert_round_trip(map)
    end

    test "lists are lists, also with a single occurrence, and keep their order" do
      map =
        simple()
        |> Map.put(:pag, %{det_pag: [%{t_pag: "01", v_pag: d("100")}]})
        |> Map.put(:cobr, %{
          dup: [
            %{n_dup: "001", d_venc: "2026-10-07", v_dup: d("50")},
            %{n_dup: "002", d_venc: "2026-11-07", v_dup: d("50")}
          ]
        })
        |> Map.put(:aut_xml, [%{cnpj: "13937073000156"}, %{cpf: "12345678909"}])

      parsed = parse!(build!(map)).nfe

      assert [%{t_pag: "01"}] = parsed.pag.det_pag
      assert [%{n_dup: "001"}, %{n_dup: "002"}] = parsed.cobr.dup
      assert [%{cnpj: "13937073000156"}, %{cpf: "12345678909"}] = parsed.aut_xml
      assert_round_trip(map)
    end

    test "several items get their nItem" do
      item = hd(simple().det)
      map = %{simple() | det: [item, item, item]}

      assert [%{n_item: "1"}, %{n_item: "2"}, %{n_item: "3"}] = parse!(build!(map)).nfe.det
      assert_round_trip(map)
    end

    test "choices, sequences inside choices, and lists in items" do
      ref = String.duplicate("3", 44)

      map =
        simple()
        |> put_in([:ide, :nf_ref], [
          %{ref_nfe: ref},
          %{ref_cte: ref},
          %{
            ref_nf: %{
              c_uf: "35",
              aamm: "2609",
              cnpj: "00000000000191",
              mod: "01",
              serie: 1,
              n_nf: 10
            }
          }
        ])
        |> put_in([:ide, :g_compra_gov], %{
          tp_ente_gov: "1",
          p_redutor: d("10"),
          tp_oper_gov: "1",
          ref_dfe_ant: [ref]
        })
        |> Map.put(:inf_adic, %{inf_cpl: "INFO", obs_cont: [%{x_campo: "A", x_texto: "B"}]})

      assert_round_trip(map)

      parsed = parse!(build!(map)).nfe
      assert [%{ref_nfe: ^ref}, %{ref_cte: ^ref}, %{ref_nf: %{c_uf: "35"}}] = parsed.ide.nf_ref

      med_rastro =
        update_item(map, fn item ->
          item
          |> put_in([:prod, :med], %{c_prod_anvisa: "1234567890123", v_pmc: d("12.5")})
          |> put_in([:prod, :rastro], [
            %{n_lote: "L1", q_lote: d("10"), d_fab: "2026-01-01", d_val: "2027-01-01"},
            %{n_lote: "L2", q_lote: d("2.5"), d_fab: "2026-02-01", d_val: "2027-02-01"}
          ])
        end)

      assert_round_trip(med_rastro)

      for ipi_trib <- [
            %{cst: "00", v_bc: d("100"), p_ipi: d("5"), v_ipi: d("5")},
            %{cst: "00", q_unid: d("2"), v_unid: d("1.5"), v_ipi: d("3")}
          ] do
        ipi = %{c_enq: "999", ipi_trib: ipi_trib}
        assert_round_trip(update_item(map, &put_in(&1, [:imposto, :ipi], ipi)))
      end

      st = %{
        orig: 0,
        cst: "10",
        mod_bc: 3,
        v_bc: d("100"),
        p_icms: d("18"),
        v_icms: d("18"),
        mod_bc_st: 4,
        p_mva_st: d("40"),
        v_bc_st: d("140"),
        p_icms_st: d("18"),
        v_icms_st: d("7.2")
      }

      assert_round_trip(update_item(map, &put_in(&1, [:imposto, :icms], %{icms10: st})))
    end

    test "contingency, with the optional sequence" do
      map =
        simple()
        |> Map.delete(:id)
        |> update_in([:ide], &Map.delete(&1, :c_dv))
        |> put_in([:ide, :tp_emis], 7)
        |> put_in([:ide, :dh_cont], "2026-09-07T09:30:00-03:00")
        |> put_in([:ide, :x_just], "SEFAZ DE ORIGEM INDISPONIVEL")

      assert {:ok, %{xml: xml}} = Builder.build_nfe(map)
      parsed = parse!(xml).nfe

      assert parsed.ide.dh_cont == "2026-09-07T09:30:00-03:00"
      assert build!(parsed) == xml
    end
  end

  # -- Documents --------------------------------------------------------------

  describe "documents" do
    test "a signed NFe reports signed?, and the signature is not returned" do
      xml = build!(simple())
      {:ok, signed} = Signer.sign_nfe(xml, Fixtures.cert())

      parsed = parse!(signed)
      assert parsed.signed? == true
      assert parsed.nfe == parse!(xml).nfe
      refute inspect(parsed) =~ "SignatureValue"
    end

    test "an nfeProc built by Proc.nfe_proc gives the protocol too" do
      xml = build!(simple())
      {:ok, signed} = Signer.sign_nfe(xml, Fixtures.cert())
      key = simple().id |> String.replace_prefix("NFe", "")
      [_, digest] = Regex.run(~r{<DigestValue>([^<]+)</DigestValue>}, signed)

      answer =
        ~s(<retEnviNFe xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00"><cStat>104</cStat>) <>
          ~s(<protNFe versao="4.00"><infProt Id="ID135"><tpAmb>2</tpAmb><verAplic>SP_NFE_PL_009</verAplic>) <>
          ~s(<chNFe>#{key}</chNFe><dhRecbto>2026-09-07T10:00:05-03:00</dhRecbto><nProt>135260000000001</nProt>) <>
          ~s(<digVal>#{digest}</digVal><cStat>100</cStat><xMotivo>Autorizado o uso da NF-e</xMotivo></infProt></protNFe>) <>
          ~s(</retEnviNFe>)

      assert {:ok, proc} = Proc.nfe_proc(signed, answer)
      parsed = parse!(proc)

      assert parsed.signed?
      assert parsed.nfe == parse!(xml).nfe

      assert parsed.protocol == %{
               versao: "4.00",
               id: "ID135",
               tp_amb: "2",
               ver_aplic: "SP_NFE_PL_009",
               ch_nfe: key,
               dh_recbto: "2026-09-07T10:00:05-03:00",
               n_prot: "135260000000001",
               dig_val: digest,
               c_stat: "100",
               x_motivo: "Autorizado o uso da NF-e"
             }
    end

    test "the supl of an NFC-e" do
      xml =
        String.replace(
          build!(document(65, 3)),
          "</NFe>",
          "<infNFeSupl><qrCode>https://example.test/?p=1&amp;x=2</qrCode>" <>
            "<urlChave>https://example.test/c</urlChave></infNFeSupl></NFe>"
        )

      parsed = parse!(xml)

      assert parsed.supl == %{
               qr_code: "https://example.test/?p=1&x=2",
               url_chave: "https://example.test/c"
             }
    end

    test "a prefixed document is read by its names" do
      xml =
        build!(simple())
        |> String.replace("<NFe xmlns=", "<n:NFe xmlns:n=")
        |> String.replace("</NFe>", "</n:NFe>")
        |> String.replace(~r{<(/?)(?!n:)(\w)}, "<\\1n:\\2")

      assert parse!(xml).nfe == parse!(build!(simple())).nfe
    end

    test "not an NFe, malformed, or with a DTD" do
      assert Builder.parse_nfe("<other xmlns=\"http://www.portalfiscal.inf.br/nfe\"/>") ==
               {:error, {:unexpected_root, "other"}}

      assert Builder.parse_nfe("<NFe/>") == {:error, {:unexpected_root, "NFe"}}
      assert Builder.parse_nfe("not xml") == {:error, {:xml, :malformed}}

      assert Builder.parse_nfe(~s(<!DOCTYPE NFe [<!ENTITY x "y">]><NFe/>)) ==
               {:error, {:xml, :dtd_forbidden}}
    end

    test "an nfeProc without the NFe" do
      assert Builder.parse_nfe(~s(<nfeProc xmlns="http://www.portalfiscal.inf.br/nfe"/>)) ==
               {:error, {:missing_element, "NFe"}}
    end

    test "a second occurrence of a single element" do
      xml =
        String.replace(
          build!(simple()),
          "</transp>",
          "</transp><transp><modFrete>9</modFrete></transp>"
        )

      assert Builder.parse_nfe(xml) == {:error, {:duplicate_element, [:inf_nfe, :transp]}}
    end
  end

  # -- Unknown elements -------------------------------------------------------

  describe "unknown elements and attributes" do
    defp with_unknown(xml),
      do: String.replace(xml, "<transp>", "<xNovo>9 &amp; 1</xNovo><transp>")

    test "are an error by default, with their path" do
      xml = with_unknown(build!(simple()))
      assert Builder.parse_nfe(xml) == {:error, {:unknown_element, [:inf_nfe, "xNovo"]}}

      nested = String.replace(build!(simple()), "<xProd>", "<xNovo>1</xNovo><xProd>")

      assert Builder.parse_nfe(nested) ==
               {:error, {:unknown_element, [:inf_nfe, :det, 0, :prod, "xNovo"]}}

      attribute = String.replace(build!(simple()), "<emit>", ~s(<emit novo="1">))

      assert Builder.parse_nfe(attribute) ==
               {:error, {:unknown_attribute, [:inf_nfe, :emit, "novo"]}}
    end

    test "strict: false keeps them under :__unknown__ as raw text" do
      xml =
        simple()
        |> build!()
        |> with_unknown()
        |> String.replace("<emit>", ~s(<emit novo="1">))
        |> String.replace("<transp>", "<transp><grupo><a>1</a><a>2</a><b>x</b></grupo>")

      assert {:ok, %{nfe: nfe}} = Builder.parse_nfe(xml, strict: false)

      assert nfe.__unknown__ == %{"xNovo" => "9 & 1"}
      assert nfe.emit.__unknown__ == %{"@novo" => "1"}
      assert nfe.transp.__unknown__ == %{"grupo" => %{"a" => ["1", "2"], "b" => "x"}}
      assert nfe.transp.mod_frete == "9"
    end

    test "a known element in another namespace is unknown" do
      xml =
        String.replace(
          build!(simple()),
          "<transp>",
          ~s(<modFrete xmlns="urn:other">9</modFrete><transp>)
        )

      assert Builder.parse_nfe(xml) == {:error, {:unknown_element, [:inf_nfe, "modFrete"]}}
    end
  end

  # -- decimals ---------------------------------------------------------------

  describe "decimals: true" do
    test "TDec leaves are Decimal, everything else stays text" do
      parsed = parse!(build!(simple()), decimals: true).nfe
      item = hd(parsed.det)

      assert item.prod.v_prod == Decimal.new("100.00")
      assert item.prod.q_com == Decimal.new("1.0000")
      assert item.imposto.icms.icms00.p_icms == Decimal.new("18.00")
      assert parsed.total.icms_tot.v_nf == Decimal.new("100.00")

      assert parsed.ide.c_uf == "35"
      assert item.prod.cfop == "5102"
      assert item.n_item == "1"
      assert parsed.id =~ "NFe"
    end

    test "a TDec text that is not a plain short decimal stays text, never parsed" do
      xml = build!(simple())

      for bad <- ["1E999999999", "-1", "inf", "NaN", String.duplicate("9", 41)] do
        evil = String.replace(xml, "<vNF>100.00</vNF>", "<vNF>#{bad}</vNF>")
        task = Task.async(fn -> parse!(evil, decimals: true).nfe.total.icms_tot.v_nf end)
        assert {:ok, ^bad} = Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)
      end
    end

    test "builds back a document with the same values" do
      xml = build!(simple())
      rebuilt = build!(parse!(xml, decimals: true).nfe)

      # a Decimal keeps no places the type does not need: 1.0000 is written 1.0
      assert hd(parse!(rebuilt).nfe.det).prod.q_com == "1.0"
      assert parse!(rebuilt, decimals: true).nfe.total == parse!(xml, decimals: true).nfe.total
    end
  end
end
