defmodule SefazNfe.MDFeMap do
  @moduledoc false
  # Test fixture for `SefazNfe.Builder.build_mdfe/2`: a road MDF-e (model 58)
  # with the groups a real one carries, as a map that mirrors the layout.
  # `Id` and `cDV` are left to the builder; `cMDF` is fixed so the key is
  # reproducible.

  @doc "A road MDF-e, emitter CNPJ (`tax_id: :cnpj`, default) or CPF."
  @spec mdfe(keyword()) :: map()
  def mdfe(opts \\ []) do
    %{
      ide: %{
        c_uf: 29,
        tp_amb: 2,
        tp_emit: 1,
        tp_transp: 1,
        mod: 58,
        serie: 1,
        n_mdf: 55,
        c_mdf: "11223344",
        modal: "1",
        dh_emi: "2026-09-07T10:00:00-03:00",
        tp_emis: 1,
        proc_emi: 0,
        ver_proc: "sefaz_nfe",
        uf_ini: "BA",
        uf_fim: "SP",
        inf_mun_carrega: [
          %{c_mun_carrega: 2_927_408, x_mun_carrega: "SALVADOR"},
          %{c_mun_carrega: 2_910_800, x_mun_carrega: "FEIRA DE SANTANA"}
        ],
        inf_percurso: [%{uf_per: "MG"}],
        dh_ini_viagem: "2026-09-08T06:00:00-03:00"
      },
      emit: emit(Keyword.get(opts, :tax_id, :cnpj)),
      inf_modal: %{
        versao_modal: "3.00",
        rodo: %{
          inf_antt: %{rntrc: "12345678"},
          veic_tracao: %{
            c_int: "T01",
            placa: "ABC1D23",
            renavam: "12345678901",
            tara: "9000",
            cap_kg: "25000",
            cap_m3: "90",
            prop: %{
              cnpj: "00000000000272",
              rntrc: "87654321",
              x_nome: "PROPRIETARIO LTDA",
              ie: "123456789",
              uf: "BA",
              tp_prop: "1"
            },
            condutor: [
              %{x_nome: "JOAO DA SILVA", cpf: "12345678909"},
              %{x_nome: "MARIA SOUZA", cpf: "98765432100"}
            ],
            tp_rod: "03",
            tp_car: "02",
            uf: "BA"
          },
          veic_reboque: [
            %{placa: "DEF2G34", tara: "6000", cap_kg: "30000", tp_car: "02", uf: "BA"},
            %{placa: "GHI3H45", tara: "6000", cap_kg: "30000", tp_car: "02"}
          ],
          lac_rodo: [%{n_lacre: "RODO-001"}]
        }
      },
      inf_doc: %{
        inf_mun_descarga: [
          %{
            c_mun_descarga: 3_550_308,
            x_mun_descarga: "SAO PAULO",
            inf_cte: [
              %{ch_cte: "29260900000000000191570010000012341123456785"},
              %{ch_cte: "29260900000000000191570010000012351123456780"}
            ],
            inf_nfe: [%{ch_nfe: "29260900000000000272550010000012341123456786"}]
          },
          %{
            c_mun_descarga: 3_509_502,
            x_mun_descarga: "CAMPINAS",
            inf_nfe: [%{ch_nfe: "29260900000000000272550010000012351123456781"}]
          }
        ]
      },
      seg: [
        %{
          inf_resp: %{resp_seg: "1", cnpj: "00000000000191"},
          inf_seg: %{x_seg: "SEGURADORA TESTE", cnpj: "00000000000353"},
          n_apol: "AP123456",
          n_aver: ["AVERB001", "AVERB002"]
        }
      ],
      prod_pred: %{tp_carga: "05", x_prod: "PRODUTOS ALIMENTICIOS", ncm: "19059090"},
      tot: %{q_cte: "2", q_nfe: "2", v_carga: "50000.00", c_unid: "01", q_carga: "12500.0000"},
      lacres: [%{n_lacre: "LACRE-001"}, %{n_lacre: "LACRE-002"}],
      inf_adic: %{inf_cpl: "MDF-E DE TESTE"}
    }
  end

  defp emit(:cnpj) do
    %{
      cnpj: "00000000000191",
      ie: "123456789",
      x_nome: "TRANSPORTADORA TESTE LTDA",
      x_fant: "TRANSPORTES TESTE",
      ender_emit: address()
    }
  end

  defp emit(:cpf) do
    %{
      cpf: "12345678909",
      ie: "123456789",
      x_nome: "TRANSPORTADOR AUTONOMO",
      ender_emit: address()
    }
  end

  defp address do
    %{
      x_lgr: "RUA DO PORTO",
      nro: "100",
      x_bairro: "COMERCIO",
      c_mun: 2_927_408,
      x_mun: "SALVADOR",
      cep: "40015000",
      uf: "BA",
      fone: "7133334444",
      email: "contato@example.com"
    }
  end
end
