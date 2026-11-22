defmodule SefazNfe.BuilderTest do
  use ExUnit.Case, async: true

  alias SefazNfe.Builder
  alias SefazNfe.Fixtures
  alias SefazNfe.NFeBuilder
  alias SefazNfe.Signer

  @pl System.get_env("SEFAZ_NFE_PL_PATH")
  @have_pl is_binary(@pl) and File.exists?(Path.join(@pl, "nfe_v4.00.xsd")) and
             System.find_executable("xmllint") != nil
  @skip_pl if(@have_pl, do: false, else: "SEFAZ_NFE_PL_PATH or xmllint is not available")

  @homologation "NF-E EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL"
  @nfce_item "NOTA FISCAL EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL"

  # -- Fixtures ---------------------------------------------------------------

  defp d(string), do: Decimal.new(string)

  # The documents `SefazNfe.NFeBuilder` writes by hand, as maps. Everything the
  # hand-written builder fixes is fixed here too; only the key is shared.
  defp document(model, crt, key) do
    %{
      id: "NFe" <> key,
      ide: ide(model, key),
      emit: emit(crt),
      dest: dest(model),
      det: [det(model, crt)],
      total: total(crt),
      transp: %{mod_frete: 9},
      pag: %{det_pag: [det_pag(model)]}
    }
    |> then(fn doc -> if doc.dest == nil, do: Map.delete(doc, :dest), else: doc end)
  end

  defp ide(model, key) do
    %{
      c_uf: 35,
      c_nf: "12345678",
      nat_op: "VENDA DE MERCADORIA",
      mod: model,
      serie: 1,
      n_nf: 1,
      dh_emi: "2026-09-07T10:00:00-03:00",
      tp_nf: 1,
      id_dest: 1,
      c_mun_fg: 3_550_308,
      tp_imp: if(model == 55, do: 1, else: 4),
      tp_emis: 1,
      c_dv: String.last(key),
      tp_amb: 2,
      fin_nfe: 1,
      ind_final: 1,
      ind_pres: 1,
      proc_emi: 0,
      ver_proc: "sefaz_nfe"
    }
  end

  defp emit(crt) do
    %{
      cnpj: "00000000000191",
      x_nome: "EMPRESA TESTE LTDA",
      x_fant: "TESTE",
      ender_emit: %{
        x_lgr: "RUA TESTE",
        nro: "100",
        x_bairro: "CENTRO",
        c_mun: 3_550_308,
        x_mun: "SAO PAULO",
        uf: "SP",
        cep: "01001000",
        c_pais: 1058,
        x_pais: "BRASIL"
      },
      ie: "110042490114",
      crt: crt
    }
  end

  defp dest(65), do: nil

  defp dest(55) do
    %{
      cnpj: "99999999000191",
      x_nome: @homologation,
      ender_dest: %{
        x_lgr: "RUA CLIENTE",
        nro: "200",
        x_bairro: "CENTRO",
        c_mun: 3_550_308,
        x_mun: "SAO PAULO",
        uf: "SP",
        cep: "01001000",
        c_pais: 1058,
        x_pais: "BRASIL"
      },
      ind_ie_dest: 9
    }
  end

  defp det(model, crt) do
    %{
      prod: %{
        c_prod: "001",
        c_ean: "SEM GTIN",
        x_prod: if(model == 65, do: @nfce_item, else: "PRODUTO TESTE"),
        ncm: "84713012",
        cfop: 5102,
        u_com: "UN",
        q_com: "1.0000",
        v_un_com: "100.0000000000",
        v_prod: d("100"),
        c_ean_trib: "SEM GTIN",
        u_trib: "UN",
        q_trib: "1.0000",
        v_un_trib: "100.0000000000",
        ind_tot: 1
      },
      imposto: Map.put(item_taxes(crt), :ibs_cbs, ibs_cbs())
    }
  end

  defp item_taxes(3) do
    %{
      icms: %{
        icms00: %{
          orig: 0,
          cst: "00",
          mod_bc: 3,
          v_bc: d("100"),
          p_icms: d("18"),
          v_icms: d("18")
        }
      },
      pis: %{pis_aliq: %{cst: "01", v_bc: d("100"), p_pis: d("1.65"), v_pis: d("1.65")}},
      cofins: %{
        cofins_aliq: %{cst: "01", v_bc: d("100"), p_cofins: d("7.6"), v_cofins: d("7.60")}
      }
    }
  end

  defp item_taxes(1) do
    %{
      icms: %{icms_sn102: %{orig: 0, csosn: "102"}},
      pis: %{pis_nt: %{cst: "07"}},
      cofins: %{cofins_nt: %{cst: "07"}}
    }
  end

  defp ibs_cbs do
    %{
      cst: "000",
      c_class_trib: "000001",
      g_ibs_cbs: %{
        v_bc: d("100"),
        g_ibs_uf: %{p_ibs_uf: "0.1000", v_ibs_uf: d("0.1")},
        g_ibs_mun: %{p_ibs_mun: "0.0000", v_ibs_mun: d("0")},
        v_ibs: d("0.1"),
        g_cbs: %{p_cbs: "0.9000", v_cbs: d("0.9")}
      }
    }
  end

  defp total(crt) do
    {v_bc, v_icms, v_pis, v_cofins} =
      case crt do
        3 -> {"100.00", "18.00", "1.65", "7.60"}
        1 -> {"0.00", "0.00", "0.00", "0.00"}
      end

    %{
      icms_tot: %{
        v_bc: v_bc,
        v_icms: v_icms,
        v_icms_deson: "0.00",
        v_fcp: "0.00",
        v_bc_st: "0.00",
        v_st: "0.00",
        v_fcp_st: "0.00",
        v_fcp_st_ret: "0.00",
        v_prod: "100.00",
        v_frete: "0.00",
        v_seg: "0.00",
        v_desc: "0.00",
        v_ii: "0.00",
        v_ipi: "0.00",
        v_ipi_devol: "0.00",
        v_pis: v_pis,
        v_cofins: v_cofins,
        v_outro: "0.00",
        v_nf: "100.00"
      },
      ibs_cbs_tot: %{
        v_bc_ibs_cbs: "100.00",
        g_ibs: %{
          g_ibs_uf: %{v_dif: "0.00", v_dev_trib: "0.00", v_ibs_uf: "0.10"},
          g_ibs_mun: %{v_dif: "0.00", v_dev_trib: "0.00", v_ibs_mun: "0.00"},
          v_ibs: "0.10",
          v_cred_pres: "0.00",
          v_cred_pres_cond_sus: "0.00"
        },
        g_cbs: %{
          v_dif: "0.00",
          v_dev_trib: "0.00",
          v_cbs: "0.90",
          v_cred_pres: "0.00",
          v_cred_pres_cond_sus: "0.00"
        }
      }
    }
  end

  defp det_pag(55), do: %{ind_pag: 0, t_pag: "01", v_pag: d("100")}
  defp det_pag(65), do: %{t_pag: "01", v_pag: d("100")}

  defp hand_written(opts) do
    NFeBuilder.build([c_nf: 12_345_678] ++ opts)
  end

  defp built!(map, opts \\ []) do
    assert {:ok, xml} = Builder.build_nfe(map, opts)
    xml
  end

  defp errors!(map) do
    assert {:error, errors} = Builder.build_nfe(map)
    errors
  end

  defp simple, do: document(55, 3, String.duplicate("1", 44))

  # -- The hand-written builder, byte for byte ---------------------------------

  describe "against SefazNfe.NFeBuilder" do
    for {label, opts, model, crt} <- [
          {"NF-e 55, regime normal (crt 3)", [], 55, 3},
          {"NF-e 55, Simples Nacional (crt 1)", [crt: 1], 55, 1},
          {"NFC-e 65", [model: 65], 65, 3}
        ] do
      test "#{label} is identical" do
        %{xml: expected, access_key: key} = hand_written(unquote(opts))

        assert built!(document(unquote(model), unquote(crt), key), declaration: true) == expected
      end
    end

    test "the only difference without the option is the XML declaration" do
      %{xml: expected, access_key: key} = hand_written([])

      assert built!(document(55, 3, key)) ==
               String.replace_prefix(expected, ~s(<?xml version="1.0" encoding="UTF-8"?>), "")
    end

    test "string keys give the same bytes" do
      %{access_key: key} = hand_written([])
      atoms = document(55, 3, key)

      assert built!(stringify(atoms)) == built!(atoms)
    end
  end

  defp stringify(%{__struct__: _} = struct), do: struct

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  # -- Errors ---------------------------------------------------------------

  describe "errors" do
    test "a required element that is missing" do
      doc = update_in(simple(), [:det, Access.at(0), :prod], &Map.delete(&1, :x_prod))

      assert [{[:det, 0, :prod, :x_prod], :required}] = errors!(doc)
    end

    test "a required element nested in an absent parent is reported at its parent's level" do
      assert [{[:ide], :required}] = errors!(Map.delete(simple(), :ide))
    end

    test "an unknown key, atom or string, at any level" do
      doc =
        simple()
        |> put_in([:emit, :x_nom], "TYPO")
        |> put_in([:det, Access.at(0), :prod, "c_prodd"], "1")
        |> Map.put(:foo, 1)

      assert [
               {[:det, 0, :prod, "c_prodd"], :unknown_key},
               {[:emit, :x_nom], :unknown_key},
               {[:foo], :unknown_key}
             ] = errors!(doc)
    end

    test "a string key is looked up, never turned into an atom" do
      name = "never_an_atom_#{System.unique_integer([:positive])}"
      doc = Map.put(simple(), name, 1)

      assert [{[^name], :unknown_key}] = errors!(doc)
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "the same key as atom and string is a duplicate" do
      doc = put_in(simple(), [:total, :icms_tot, "v_nf"], "100.00")

      assert [{[:total, :icms_tot, :v_nf], :duplicate_key}] = errors!(doc)
    end

    test "occurs: too few, too many, not a list" do
      assert [{[:det], {:occurs, 1, 990, 0}}] = errors!(%{simple() | det: []})

      many = List.duplicate(hd(simple().det), 991)
      assert {[:det], {:occurs, 1, 990, 991}} in errors!(%{simple() | det: many})

      assert [{[:det], :not_a_list}] = errors!(%{simple() | det: hd(simple().det)})

      doc = Map.put(simple(), :aut_xml, List.duplicate(%{cnpj: "00000000000191"}, 11))
      assert [{[:aut_xml], {:occurs, 0, 10, 11}}] = errors!(doc)
    end

    test "choice: none and many" do
      doc = put_in(simple(), [:emit], Map.delete(simple().emit, :cnpj))
      assert [{[:emit], :choice_none}] = errors!(doc)

      doc = put_in(simple(), [:emit, :cpf], "12345678909")
      assert [{[:emit], {:choice_many, [:cnpj, :cpf]}}] = errors!(doc)

      icms = %{icms00: %{}, icms_sn102: %{}}
      doc = put_in(simple(), [:det, Access.at(0), :imposto, :icms], icms)
      assert [{[:det, 0, :imposto, :icms], {:choice_many, [:icms00, :icms_sn102]}}] = errors!(doc)

      doc = put_in(simple(), [:det, Access.at(0), :imposto, :icms], %{})
      assert [{[:det, 0, :imposto, :icms], :choice_none}] = errors!(doc)
    end

    test "choice with sequence branches: ambiguity and mixed branches" do
      item = hd(simple().det)

      # ipi alone fits both branches of imposto (icms/ipi/ii or ipi/issqn).
      doc = %{
        simple()
        | det: [put_in(item, [:imposto, :ipi], %{}) |> pop_in([:imposto, :icms]) |> elem(1)]
      }

      assert [{[:det, 0, :imposto], {:choice_ambiguous, [:ipi]}}] = errors!(doc)

      # icms and issqn live in different branches.
      doc = %{simple() | det: [put_in(item, [:imposto, :issqn], %{})]}
      assert [{[:det, 0, :imposto], {:choice_many, [:icms, :issqn]}}] = errors!(doc)

      # v_bc/p_ipi and q_unid/v_unid are the two branches of ipi_trib.
      ipi = %{c_enq: "999", ipi_trib: %{cst: "00", v_bc: "1.00", q_unid: "1.0000", v_ipi: "1.00"}}
      doc = %{simple() | det: [put_in(item, [:imposto, :ipi], ipi)]}

      assert [{[:det, 0, :imposto, :ipi, :ipi_trib], {:choice_many, [:v_bc, :q_unid]}}] =
               errors!(doc)
    end

    test "an optional sequence needs all its members once started" do
      doc = put_in(simple(), [:ide, :dh_cont], "2026-09-07T09:30:00-03:00")

      assert [{[:ide, :x_just], :required}] = errors!(doc)
    end

    test "pattern, enumeration and length" do
      assert [{[:ide, :c_nf], {:pattern, "[0-9]{8}"}}] =
               errors!(put_in(simple(), [:ide, :c_nf], "1234"))

      assert [{[:ide, :tp_nf], {:enum, ["0", "1"]}}] =
               errors!(put_in(simple(), [:ide, :tp_nf], 2))

      assert [{[:emit, :x_nome], {:max_length, 60}}] =
               errors!(put_in(simple(), [:emit, :x_nome], String.duplicate("A", 61)))
    end

    test "lengths count characters, not bytes" do
      ok = put_in(simple(), [:emit, :x_nome], String.duplicate("Ç", 60))
      assert {:ok, _xml} = Builder.build_nfe(ok)

      too_long = put_in(simple(), [:emit, :x_nome], String.duplicate("Ç", 61))
      assert [{[:emit, :x_nome], {:max_length, 60}}] = errors!(too_long)
    end

    test "every pattern a type inherits has to match" do
      # TCEP-like types are single pattern; the id attribute is a TChNFe-style one.
      assert [{[:id], {:pattern, _}}] = errors!(%{simple() | id: "NFe123"})
    end

    test "decimal precision is never rounded" do
      doc = put_in(simple(), [:total, :icms_tot, :v_nf], d("1.005"))
      assert [{[:total, :icms_tot, :v_nf], {:precision, 2}}] = errors!(doc)

      doc =
        put_in(simple(), [:det, Access.at(0), :imposto, :icms, :icms00, :p_icms], d("18.00001"))

      assert [{[:det, 0, :imposto, :icms, :icms00, :p_icms], {:precision, 4}}] = errors!(doc)
    end

    test "floats, and anything that is not text or a number" do
      assert [{[:total, :icms_tot, :v_nf], :float_not_allowed}] =
               errors!(put_in(simple(), [:total, :icms_tot, :v_nf], 100.0))

      assert [{[:ide, :c_nf], :invalid_type}] = errors!(put_in(simple(), [:ide, :c_nf], :atom))
      assert [{[:ide, :c_nf], :invalid_type}] = errors!(put_in(simple(), [:ide, :c_nf], %{}))
      assert [{[:ide], :invalid_type}] = errors!(put_in(simple(), [:ide], "x"))
      assert [{[], :invalid_type}] = Builder.build_nfe(:nope) |> elem(1)
    end

    test "invalid UTF-8 and XML control characters" do
      assert [{[:ide, :nat_op], :invalid_utf8}] =
               errors!(put_in(simple(), [:ide, :nat_op], <<255, 254>>))

      assert [{[:ide, :nat_op], :invalid_xml_char}] =
               errors!(put_in(simple(), [:ide, :nat_op], "A\x01B"))
    end

    test "nItem: the position, or the same number, nothing else" do
      item = hd(simple().det)

      xml =
        built!(%{simple() | det: [item, Map.put(item, :n_item, 2), Map.put(item, "n_item", "3")]})

      assert xml =~ ~s(<det nItem="1">)
      assert xml =~ ~s(<det nItem="2">)
      assert xml =~ ~s(<det nItem="3">)

      assert [{[:det, 1, :n_item], {:invalid_n_item, 2}}] =
               errors!(%{simple() | det: [item, Map.put(item, :n_item, 5)]})
    end

    test "versao is 4.00 and nothing else" do
      assert built!(Map.put(simple(), :versao, "4.00")) =~ ~s(versao="4.00")
      assert [{[:versao], {:pattern, "4\\.00"}}] = errors!(Map.put(simple(), :versao, "3.10"))
    end

    test "the Id is required" do
      assert [{[:id], :required}] = errors!(Map.delete(simple(), :id))
    end

    test "every error is collected, with its path, sorted" do
      doc =
        simple()
        |> put_in([:ide, :c_nf], "x")
        |> put_in([:emit, :crt], 7)
        |> put_in([:det, Access.at(0), :prod], %{x_prod: 1.5})
        |> put_in([:total, :icms_tot, :v_nf], d("1.005"))
        |> Map.put(:typo, 1)

      errors = errors!(doc)

      assert {[:ide, :c_nf], {:pattern, "[0-9]{8}"}} in errors
      assert {[:emit, :crt], {:enum, ["1", "2", "3", "4"]}} in errors
      assert {[:det, 0, :prod, :x_prod], :float_not_allowed} in errors
      assert {[:det, 0, :prod, :c_prod], :required} in errors
      assert {[:total, :icms_tot, :v_nf], {:precision, 2}} in errors
      assert {[:typo], :unknown_key} in errors
      assert errors == Enum.sort(errors)
      assert length(errors) > 10
    end
  end

  # -- Values ---------------------------------------------------------------

  describe "values" do
    defp v_nf(value) do
      xml = built!(put_in(simple(), [:total, :icms_tot, :v_nf], value))
      [_, text] = Regex.run(~r{<vNF>([^<]*)</vNF>}, xml)
      text
    end

    test "Decimal and integer are written with the places of the type" do
      assert v_nf(d("100")) == "100.00"
      assert v_nf(100) == "100.00"
      assert v_nf(d("1.5")) == "1.50"
      assert v_nf(d("1.50")) == "1.50"
      assert v_nf(d("1E+2")) == "100.00"
      assert v_nf(d("0")) == "0.00"
      assert v_nf(d("0.10")) == "0.10"
      assert v_nf("100.00") == "100.00"
    end

    test "types with a range of places use the least, and keep what the value needs" do
      p = fn value ->
        xml =
          built!(put_in(simple(), [:det, Access.at(0), :imposto, :icms, :icms00, :p_icms], value))

        [_, text] = Regex.run(~r{<pICMS>([^<]*)</pICMS>}, xml)
        text
      end

      assert p.(d("18")) == "18.00"
      assert p.(d("18.5")) == "18.50"
      assert p.(d("18.123")) == "18.123"
      assert p.(d("18.1234")) == "18.1234"
      assert p.(d("18.1200")) == "18.12"
    end

    test "a type with a variable number of places starts at one" do
      qty = fn value ->
        xml = built!(put_in(simple(), [:det, Access.at(0), :prod, :q_com], value))
        [_, text] = Regex.run(~r{<qCom>([^<]*)</qCom>}, xml)
        text
      end

      assert qty.(d("2")) == "2.0"
      assert qty.(d("2.5")) == "2.5"
      assert qty.(d("2.1234")) == "2.1234"

      doc = put_in(simple(), [:det, Access.at(0), :prod, :q_com], d("2.12345"))
      assert [{[:det, 0, :prod, :q_com], {:precision, 4}}] = errors!(doc)
    end

    test "a Decimal for a text type is invalid, an integer is stringified" do
      assert [{[:ide, :c_nf], :invalid_type}] =
               errors!(put_in(simple(), [:ide, :c_nf], d("12345678")))

      assert built!(put_in(simple(), [:ide, :c_nf], 12_345_678)) =~ "<cNF>12345678</cNF>"
    end

    test "text is only XML-escaped" do
      xml = built!(put_in(simple(), [:ide, :nat_op], ~s(VENDA & "TROCA" <A> 'B')))

      assert xml =~ "<natOp>VENDA &amp; &quot;TROCA&quot; &lt;A&gt; &apos;B&apos;</natOp>"
    end

    test "nil is the same as absent" do
      assert built!(put_in(simple(), [:emit, :x_fant], nil)) =~ "</xNome><enderEmit>"
      assert [{[:emit, :x_nome], :required}] = errors!(put_in(simple(), [:emit, :x_nome], nil))
    end

    test "a base64 leaf is checked as base64, with its length in octets" do
      resp = %{
        cnpj: "00000000000191",
        x_contato: "FULANO",
        email: "a@b.com",
        fone: "11999999999"
      }

      assert {:ok, _} = Builder.build_nfe(Map.put(simple(), :inf_resp_tec, resp))

      csrt =
        Map.merge(resp, %{id_csrt: "01", hash_csrt: Base.encode64(:crypto.strong_rand_bytes(20))})

      assert {:ok, xml} = Builder.build_nfe(Map.put(simple(), :inf_resp_tec, csrt))
      assert xml =~ "<idCSRT>01</idCSRT>"

      bad = %{csrt | hash_csrt: Base.encode64("short")}

      assert [{[:inf_resp_tec, :hash_csrt], {:length, 20}}] =
               errors!(Map.put(simple(), :inf_resp_tec, bad))

      bad = %{csrt | hash_csrt: "***"}

      assert [{[:inf_resp_tec, :hash_csrt], :invalid_base64}] =
               errors!(Map.put(simple(), :inf_resp_tec, bad))
    end
  end

  # -- Order and determinism ----------------------------------------------------

  describe "key order" do
    test "the output follows the layout, whatever the keys and their iteration order" do
      doc = simple()
      expected = built!(doc)

      for seed <- 1..25 do
        :rand.seed(:exsss, {seed, seed * 7, seed * 13})
        assert built!(mix_keys(doc)) == expected
      end
    end

    test "lists keep their order, which is the document's" do
      item = hd(simple().det)
      second = put_in(item, [:prod, :c_prod], "002")
      xml = built!(%{simple() | det: [item, second]})

      assert Regex.scan(~r{<cProd>(\d+)</cProd>}, xml, capture: :all_but_first) == [
               ["001"],
               ["002"]
             ]
    end
  end

  # Elixir maps have no insertion order and small ones iterate by key, so the
  # way to hand the builder a different order is to change the keys: each one
  # is randomly an atom or a string, which reorders the iteration at every level.
  defp mix_keys(%{__struct__: _} = struct), do: struct

  defp mix_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {if(:rand.uniform(2) == 1, do: to_string(k), else: k), mix_keys(v)}
    end)
  end

  defp mix_keys(list) when is_list(list), do: Enum.map(list, &mix_keys/1)
  defp mix_keys(other), do: other

  # -- Performance -----------------------------------------------------------

  describe "performance" do
    test "a 50 item NF-e builds in well under a second" do
      item = hd(simple().det)
      doc = %{simple() | det: List.duplicate(item, 50)}

      # Warm the code paths once, then time the median of a few runs.
      built!(doc)

      times =
        for _ <- 1..5 do
          {microseconds, {:ok, _xml}} = :timer.tc(fn -> Builder.build_nfe(doc) end)
          microseconds
        end

      median = times |> Enum.sort() |> Enum.at(2)
      assert median < 200_000, "median #{median}us for 50 items"
    end
  end

  # -- The real schema ---------------------------------------------------------

  describe "against the real PL_010 schema (xmllint)" do
    @tag skip: @skip_pl
    test "NF-e 55 with IBS/CBS, crt 3 and crt 1" do
      for crt <- [3, 1] do
        assert validate(document(55, crt, key(55))) == :ok
      end
    end

    @tag skip: @skip_pl
    test "NFC-e 65" do
      assert validate(document(65, 3, key(65))) == :ok
      assert validate(document(65, 1, key(65))) == :ok
    end

    @tag skip: @skip_pl
    test "ICMS-ST (icms10 with FCP) and the Simples Nacional ST variants" do
      st = %{
        orig: 0,
        cst: "10",
        mod_bc: 3,
        v_bc: d("100"),
        p_icms: d("18"),
        v_icms: d("18"),
        v_bc_fcp: d("100"),
        p_fcp: d("2"),
        v_fcp: d("2"),
        mod_bc_st: 4,
        p_mva_st: d("40"),
        v_bc_st: d("140"),
        p_icms_st: d("18"),
        v_icms_st: d("7.2")
      }

      assert validate(with_icms(%{icms10: st})) == :ok

      st60 = %{orig: 0, cst: "60", v_bc_st_ret: d("100"), p_st: d("18"), v_icms_st_ret: d("18")}
      assert validate(with_icms(%{icms60: st60})) == :ok

      sn201 = %{
        orig: 0,
        csosn: "201",
        mod_bc_st: 4,
        v_bc_st: d("140"),
        p_icms_st: d("18"),
        v_icms_st: d("7.2"),
        p_cred_sn: d("1.5"),
        v_cred_icms_sn: d("1.5")
      }

      assert validate(with_icms(%{icms_sn201: sn201})) == :ok
    end

    @tag skip: @skip_pl
    test "DIFAL (icms_uf_dest)" do
      difal = %{
        v_bc_uf_dest: d("100"),
        p_fcp_uf_dest: d("2"),
        p_icms_uf_dest: d("18"),
        p_icms_inter: "12.00",
        p_icms_inter_part: d("100"),
        v_fcp_uf_dest: d("2"),
        v_icms_uf_dest: d("6"),
        v_icms_uf_remet: d("0")
      }

      doc = update_item(&put_in(&1, [:imposto, :icms_uf_dest], difal))
      assert validate(doc) == :ok
    end

    @tag skip: @skip_pl
    test "med and rastro (a list)" do
      doc =
        update_item(fn item ->
          item
          |> put_in([:prod, :med], %{c_prod_anvisa: "1234567890123", v_pmc: d("12.5")})
          |> put_in([:prod, :rastro], [
            %{n_lote: "L1", q_lote: d("10"), d_fab: "2026-01-01", d_val: "2027-01-01"},
            %{
              n_lote: "L2",
              q_lote: d("2.5"),
              d_fab: "2026-02-01",
              d_val: "2027-02-01",
              c_agreg: "X"
            }
          ])
        end)

      assert validate(doc) == :ok
    end

    @tag skip: @skip_pl
    test "dup (a list), det_pag (a list) and aut_xml" do
      doc =
        simple()
        |> Map.put(:cobr, %{
          fat: %{n_fat: "001", v_orig: d("100"), v_desc: d("0"), v_liq: d("100")},
          dup: [
            %{n_dup: "001", d_venc: "2026-10-07", v_dup: d("50")},
            %{n_dup: "002", d_venc: "2026-11-07", v_dup: d("50")}
          ]
        })
        |> Map.put(:pag, %{
          det_pag: [
            %{ind_pag: 1, t_pag: "03", v_pag: d("60"), card: %{tp_integra: "2"}},
            %{ind_pag: 0, t_pag: "01", v_pag: d("40")}
          ],
          v_troco: d("0")
        })
        |> Map.put(:aut_xml, [%{cnpj: "13937073000156"}, %{cpf: "12345678909"}])

      assert validate(doc) == :ok
    end

    @tag skip: @skip_pl
    test "ref_nfe and the other nf_ref choices, and the referenced DF-e of a government purchase" do
      ref = String.duplicate("3", 44)

      doc =
        put_in(simple(), [:ide, :nf_ref], [
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

      assert validate(doc) == :ok

      doc =
        put_in(simple(), [:ide, :g_compra_gov], %{
          tp_ente_gov: "1",
          p_redutor: d("10"),
          tp_oper_gov: "1",
          ref_dfe_ant: [ref]
        })

      assert validate(doc) == :ok
    end

    @tag skip: @skip_pl
    test "contingency (dh_cont and x_just), info and IPI with the sequence branches" do
      doc =
        simple()
        |> put_in([:ide, :tp_emis], 7)
        |> put_in([:ide, :dh_cont], "2026-09-07T09:30:00-03:00")
        |> put_in([:ide, :x_just], "SEFAZ DE ORIGEM INDISPONIVEL")
        |> Map.put(:inf_adic, %{inf_cpl: "INFORMACAO", obs_cont: [%{x_campo: "A", x_texto: "B"}]})

      assert validate(doc) == :ok

      ipi_valor = %{
        c_enq: "999",
        ipi_trib: %{cst: "00", v_bc: d("100"), p_ipi: d("5"), v_ipi: d("5")}
      }

      ipi_unid = %{
        c_enq: "999",
        ipi_trib: %{cst: "00", q_unid: d("2"), v_unid: d("1.5"), v_ipi: d("3")}
      }

      for ipi <- [ipi_valor, ipi_unid] do
        assert validate(update_item(&put_in(&1, [:imposto, :ipi], ipi))) == :ok
      end
    end

    defp key(model), do: hand_written(model: model).access_key

    defp update_item(fun) do
      doc = simple()
      %{doc | det: [fun.(hd(doc.det))]}
    end

    defp with_icms(icms), do: update_item(&put_in(&1, [:imposto, :icms], icms))

    # Signs with the test certificate, which also shows Signer takes the output.
    defp validate(map) do
      {:ok, xml} = Builder.build_nfe(map)
      {:ok, signed} = Signer.sign_nfe(xml, Fixtures.cert())

      file = Path.join(System.tmp_dir!(), "builder_#{System.unique_integer([:positive])}.xml")
      File.write!(file, signed)

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
end
