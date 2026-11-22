defmodule SefazNfe.NFeMap do
  @moduledoc false
  # Test fixture: the documents `SefazNfe.NFeBuilder` writes as XML, as maps for
  # `SefazNfe.Builder`.

  @homologation "NF-E EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL"
  @nfce_item "NOTA FISCAL EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL"

  defp d(string), do: Decimal.new(string)

  # The documents `SefazNfe.NFeBuilder` writes by hand, as maps. Everything the
  # hand-written builder fixes is fixed here too; only the key is shared.
  @doc "The map form of what `SefazNfe.NFeBuilder` writes by hand."
  @spec document(55 | 65, 1 | 3, String.t()) :: map()
  def document(model, crt, key) do
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
end
