defmodule SefazNfe.CTeMap do
  @moduledoc false
  # Test fixtures for `SefazNfe.Builder.build_cte/2` and `build_cte_os/2`: a
  # realistic road CT-e (model 57) and a road CT-e OS (model 67), as maps that
  # mirror the layout. Values are the ones a host would send; nothing is
  # calculated here. `Id`, `cDV` are left to the builder; `cCT` is fixed so the
  # key is reproducible.

  @doc "A normal CT-e, road modal, ICMS 00 (default) or ICMSSN, with IBS/CBS."
  @spec cte(keyword()) :: map()
  def cte(opts \\ []) do
    icms =
      case Keyword.get(opts, :icms, :icms00) do
        :icms00 ->
          %{icms00: %{cst: "00", v_bc: "1000.00", p_icms: "12.00", v_icms: "120.00"}}

        :icms_sn ->
          %{icms_sn: %{cst: "90", ind_sn: "1"}}
      end

    %{
      ide: %{
        c_uf: 29,
        c_ct: "12345679",
        cfop: "6353",
        nat_op: "PRESTACAO DE SERVICO DE TRANSPORTE",
        mod: 57,
        serie: 1,
        n_ct: 1234,
        dh_emi: "2026-09-07T10:00:00-03:00",
        tp_imp: 1,
        tp_emis: 1,
        tp_amb: 2,
        tp_cte: 0,
        proc_emi: 0,
        ver_proc: "sefaz_nfe",
        c_mun_env: 2_927_408,
        x_mun_env: "SALVADOR",
        uf_env: "BA",
        modal: "01",
        tp_serv: 0,
        c_mun_ini: 2_927_408,
        x_mun_ini: "SALVADOR",
        uf_ini: "BA",
        c_mun_fim: 3_550_308,
        x_mun_fim: "SAO PAULO",
        uf_fim: "SP",
        retira: 1,
        ind_ie_toma: 1,
        toma3: %{toma: "3"}
      },
      compl: %{
        x_carac_ad: "TRANSPORTE",
        x_emi: "EMPRESA TESTE",
        fluxo: %{x_orig: "SALVADOR", pass: [%{x_pass: "FEIRA SANTANA"}], x_dest: "SAO PAULO"},
        x_obs: "CT-E DE TESTE",
        obs_cont: [%{x_campo: "PEDIDO", x_texto: "4500012345"}]
      },
      emit: %{
        cnpj: "00000000000191",
        ie: "123456789",
        x_nome: "TRANSPORTADORA TESTE LTDA",
        x_fant: "TRANSPORTES TESTE",
        ender_emit: %{
          x_lgr: "RUA DO PORTO",
          nro: "100",
          x_bairro: "COMERCIO",
          c_mun: 2_927_408,
          x_mun: "SALVADOR",
          cep: "40015000",
          uf: "BA",
          fone: "7133334444"
        },
        crt: 3
      },
      rem: party("REMETENTE LTDA", "00000000000272", :ender_reme, 2_927_408, "SALVADOR", "BA"),
      exped: party("EXPEDIDOR LTDA", "00000000000353", :ender_exped, 2_927_408, "SALVADOR", "BA"),
      dest: party("DESTINATARIO SA", "00000000000434", :ender_dest, 3_550_308, "SAO PAULO", "SP"),
      v_prest: %{
        v_t_prest: "1200.50",
        v_rec: "1200.50",
        comp: [
          %{x_nome: "FRETE VALOR", v_comp: "1000.00"},
          %{x_nome: "PEDAGIO", v_comp: "200.50"}
        ]
      },
      imp: %{
        icms: icms,
        v_tot_trib: "120.00",
        ibs_cbs: %{
          cst: "000",
          c_class_trib: "000001",
          g_ibs_cbs: %{
            v_bc: "1000.00",
            g_ibs_uf: %{p_ibs_uf: "0.10", v_ibs_uf: "1.00"},
            g_ibs_mun: %{p_ibs_mun: "0.00", v_ibs_mun: "0.00"},
            v_ibs: "1.00",
            g_cbs: %{p_cbs: "0.90", v_cbs: "9.00"}
          }
        }
      },
      inf_cte_norm: %{
        inf_carga: %{
          v_carga: "50000.00",
          pro_pred: "PRODUTOS ALIMENTICIOS",
          x_out_cat: "PALETIZADA",
          inf_q: [
            %{c_unid: "01", tp_med: "PESO BRUTO", q_carga: "12500.0000"},
            %{c_unid: "03", tp_med: "VOLUMES", q_carga: "250.0000"}
          ]
        },
        inf_doc: %{
          inf_nfe: [
            %{chave: "29260900000000000272550010000012341123456786"},
            %{chave: "29260900000000000272550010000012351123456781"}
          ]
        },
        inf_modal: %{
          versao_modal: "4.00",
          rodo: %{rntrc: "12345678"}
        }
      },
      inf_resp_tec: %{
        cnpj: "00000000000191",
        x_contato: "SUPORTE",
        email: "suporte@example.com",
        fone: "7133334444"
      }
    }
  end

  @doc "A CT-e OS (model 67), road modal with a TAF, ICMS 00."
  @spec cte_os(keyword()) :: map()
  def cte_os(_opts \\ []) do
    %{
      ide: %{
        c_uf: 29,
        c_ct: "87654321",
        cfop: "6353",
        nat_op: "TRANSPORTE DE PESSOAS",
        mod: 67,
        serie: 1,
        n_ct: 77,
        dh_emi: "2026-09-07T10:00:00-03:00",
        tp_imp: 1,
        tp_emis: 1,
        tp_amb: 2,
        tp_cte: 0,
        proc_emi: 0,
        ver_proc: "sefaz_nfe",
        c_mun_env: 2_927_408,
        x_mun_env: "SALVADOR",
        uf_env: "BA",
        modal: "01",
        tp_serv: 6,
        ind_ie_toma: 1,
        uf_ini: "BA",
        uf_fim: "SP",
        inf_percurso: [%{uf_per: "MG"}]
      },
      compl: %{x_carac_ad: "FRETAMENTO", x_obs: "CT-E OS DE TESTE"},
      emit: %{
        cnpj: "00000000000191",
        ie: "123456789",
        x_nome: "TRANSPORTADORA TESTE LTDA",
        ender_emit: %{
          x_lgr: "RUA DO PORTO",
          nro: "100",
          x_bairro: "COMERCIO",
          c_mun: 2_927_408,
          x_mun: "SALVADOR",
          cep: "40015000",
          uf: "BA"
        },
        crt: 3
      },
      toma: %{
        cnpj: "00000000000272",
        ie: "123456789",
        x_nome: "TOMADOR LTDA",
        ender_toma: %{
          x_lgr: "AV TOMADOR",
          nro: "10",
          x_bairro: "CENTRO",
          c_mun: 3_550_308,
          x_mun: "SAO PAULO",
          cep: "01001000",
          uf: "SP"
        }
      },
      v_prest: %{
        v_t_prest: "800.00",
        v_rec: "800.00",
        comp: [%{x_nome: "FRETE", v_comp: "800.00"}]
      },
      imp: %{
        icms: %{icms00: %{cst: "00", v_bc: "800.00", p_icms: "12.00", v_icms: "96.00"}}
      },
      inf_cte_norm: %{
        inf_servico: %{x_desc_serv: "TRANSPORTE DE PASSAGEIROS", inf_q: %{q_carga: "40.0000"}},
        seg: [%{resp_seg: "4", x_seg: "SEGURADORA TESTE", n_apol: "AP123"}],
        inf_modal: %{
          versao_modal: "4.00",
          rodo_os: %{
            taf: "123456789012",
            veic: %{placa: "ABC1D23", renavam: "12345678901", uf: "BA"}
          }
        }
      }
    }
  end

  defp party(name, cnpj, ender, c_mun, x_mun, uf) do
    %{
      cnpj: cnpj,
      ie: "123456789",
      x_nome: name,
      fone: "1133334444",
      email: "contato@example.com"
    }
    |> Map.put(ender, %{
      x_lgr: "RUA " <> name,
      nro: "1",
      x_bairro: "CENTRO",
      c_mun: c_mun,
      x_mun: x_mun,
      cep: "01001000",
      uf: uf
    })
  end
end
