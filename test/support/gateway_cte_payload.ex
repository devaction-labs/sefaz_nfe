defmodule SefazNfe.GatewayCtePayload do
  @moduledoc false
  # Test support: translates the CT-e (model 57) and CT-e OS (model 67) request payload of
  # the `fiscal-gateway` HTTP contract (English snake_case, decoded JSON with string keys)
  # into the input of `SefazNfe.Builder.build_cte/2` / `build_cte_os/2`. A PROTOTYPE of the
  # mapping the future Phoenix API needs; it reproduces what the gateway's
  # `app/Pipelines/Cte/BuildCteXml.php` and `BuildCteOsXml.php` (gateway sha in
  # test/golden/expected/GATEWAY_SHA) do when they feed sped-cte's `MakeCTe` / `MakeCTeOS`
  # (NFePHP/CTe, vendor/nfephp-org/sped-cte/src). Three kinds of rule live here:
  #
  #   * NAMES    gateway field -> layout key (a plain rename).
  #   * BRANCH   the gateway's choice of the layout variant (the builder never infers one):
  #              BuildCteXml.php `taker/2` picks `toma3` for a role other than 4 and `toma4`
  #              for role 4; `icms/2` maps `simples_nacional: true` to the `SN` literal;
  #              MakeCTe::tagicms (l.2851) then picks the `ICMSxx` element from the CST
  #              (`switch ($std->cst)` l.2884: 00, 20, 40/41/51 -> ICMS45, 60, 90 ->
  #              ICMSOutraUF when `outraUF` else ICMS90, SN -> ICMSSN CST 90 indSN 1 l.3225).
  #   * FORMAT   NFePHP pads every number to the places of its field
  #              (`conditionalNumberFormatting($v, $places)`, default 2), see
  #              `SefazNfe.GatewayCommon.dec/2`.
  #
  # NFePHP-side behaviours reproduced here (never in lib):
  #
  #   * `cCT` is the random code of the key (BuildCteXml.php `accessKeyFor/1`, `identification/3`:
  #     `substr($accessKey, 35, 8)`): the context's `numeric_code` (Keys::random() in production).
  #   * `dhEmi` is the issue time in the timezone of the COMPANY's UF (TimeZoneByUF).
  #   * Homologation (`tpAmb` 2): MakeCTe::tagrem/tagexped/tagreceb/tagdest (l.2089, 2275, 2454,
  #     2634) write `xNome` = "CTE EMITIDO EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL"; every
  #     one of them cuts `xNome` at 60 characters (`substr(trim($xNome), 0, 60)`). `toma4`
  #     (l.1235) and the CT-e OS `toma` (MakeCTeOS::tagtomador, l.1053) are not rewritten.
  #   * ICMS fields written only when positive: `pRedBCOutraUF` (when `vICMSOutraUF` > 0),
  #     `pRedBC` of ICMS90, `vCred`, `vTotTrib` (`$std->vTotTrib > 0`, l.3249); `infAdFisco` when
  #     given (l.3252).
  #   * IBS/CBS (MakeCTe::tagIBSCBS l.5211): `gIBSCBS` only when `vBC` is numeric; places `pIBSUF`
  #     4, `pIBSMun` 2, `pCBS` 4, money 2; `vIBS` is computed as `vIBSUF + vIBSMun` when absent
  #     (API requirement below); the regular-tax group (`tagIBSCBSTribRegular` l.5545) is a child
  #     of `gIBSCBS` (`gTribRegular`, l.629) with places 4/2; `vTotDFe` follows `IBSCBS` and is
  #     written only when `IBSCBS` was built (l.626-643).
  #   * CT-e OS: `prop` (vehicle owner) is written only when the owner has a name
  #     (MakeCTeOS::tagveic), `TAF` wins over `NroRegEstadual` (tagrodo l.1956, tagveic), the
  #     owner's `IE` keeps digits only (`Strings::onlyNumbers`), `infDocRef` takes `chBPe` or
  #     else the manual-document fields (taginfDocRef l.1832).
  #
  # API REQUIREMENTS found while writing this (what the HTTP API must do for the host):
  #
  #   * NFePHP computes `vIBS` (= vIBSUF + vIBSMun) when `ibs_amount` is absent. The builder does
  #     no arithmetic (AD-001/AD-021), so the API must require `ibs_amount` or sum it itself.
  #   * `number_format` ROUNDS to the field's places; this mapping only pads. A client value with
  #     more places than the field holds must be rejected (or rounded) by the API.
  #   * `ide.c_dv` and `Id` come from the builder's key; nothing else is computed by NFePHP in the
  #     CT-e (no totals), so no further arithmetic is needed.
  #
  # `opts[:context]` is the part of the issuance the gateway keeps outside the payload
  # (`CteIssuanceContext`: company, model, series, number, cCT, emission type, environment,
  # issue time), as the JSON in test/golden/contexts.

  import SefazNfe.GatewayCommon

  @homologation_name "CTE EMITIDO EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL"

  @spec to_builder_map(map(), keyword()) :: map()
  def to_builder_map(payload, opts) do
    ctx = Keyword.fetch!(opts, :context)

    case ctx["model"] do
      57 -> cte(payload, ctx)
      67 -> cte_os(payload, ctx)
    end
  end

  # -- CT-e (BuildCteXml::handle) ----------------------------------------------------------

  defp cte(p, ctx) do
    homolog? = ctx["environment"] == 2

    %{
      ide: ide(p, ctx, 57, :cte),
      compl: compl(p["additional_info"]),
      emit: emit(ctx["company"]),
      rem: party(p["sender"], homolog?, :ender_reme, true),
      exped: party(p["dispatcher"], homolog?, :ender_exped, false),
      receb: party(p["receiver"], homolog?, :ender_receb, false),
      dest: dest(p["recipient"], homolog?),
      v_prest: v_prest(p["service_amount"]),
      imp: imp(p["taxes"], :cte),
      inf_cte_norm: %{
        inf_carga: inf_carga(p["cargo"]),
        inf_doc: inf_doc(p["documents"]),
        inf_modal: %{versao_modal: "4.00", rodo: %{rntrc: p["road"]["rntrc"]}}
      }
    }
    |> reject_nil()
  end

  # -- CT-e OS (BuildCteOsXml::handle) -----------------------------------------------------

  defp cte_os(p, ctx) do
    %{
      ide: ide(p, ctx, 67, :cte_os),
      compl: compl(p["additional_info"]),
      emit: emit(ctx["company"]),
      toma: toma(p["taker"]),
      v_prest: v_prest(p["service_amount"]),
      imp: imp(p["taxes"], :cte_os),
      inf_cte_norm:
        reject_nil(%{
          inf_servico: inf_servico(p["service"]),
          inf_doc_ref: inf_doc_ref(p["referenced_documents"]),
          seg: seg(p["insurance"]),
          inf_modal: %{versao_modal: "4.00", rodo_os: rodo_os(p["road"])}
        })
    }
    |> reject_nil()
  end

  # -- ide ---------------------------------------------------------------------------------

  defp ide(p, ctx, model, kind) do
    i = p["identification"]
    company = ctx["company"]

    base = %{
      c_uf: uf_code(company["state"]),
      c_ct: ctx["numeric_code"],
      cfop: i["cfop"],
      nat_op: i["operation_nature"],
      mod: model,
      serie: ctx["series"],
      n_ct: ctx["number"],
      dh_emi: issued_at(ctx["issued_at"], company["state"]),
      tp_imp: 1,
      tp_emis: ctx["emission_type"],
      tp_amb: ctx["environment"],
      tp_cte: 0,
      proc_emi: 0,
      ver_proc: "fiscal-gateway",
      c_mun_env: company["city_ibge_code"],
      x_mun_env: company["city_name"],
      uf_env: company["state"],
      modal: "01",
      tp_serv: i["service_type"],
      c_mun_ini: i["start_city_ibge_code"],
      x_mun_ini: i["start_city_name"],
      uf_ini: i["start_state"],
      c_mun_fim: i["end_city_ibge_code"],
      x_mun_fim: i["end_city_name"],
      uf_fim: i["end_state"],
      ind_ie_toma: i["taker_state_registration_indicator"]
    }

    specific =
      case kind do
        :cte ->
          %{
            retira: i["receiver_picks_up"],
            x_det_retira: i["pickup_details"]
          }
          |> Map.merge(toma_choice(p["taker"]))

        :cte_os ->
          # BuildCteOsXml::routeStates: one infPercurso per state
          %{inf_percurso: for(uf <- i["route_states"] || [], do: %{uf_per: uf})}
      end

    base |> Map.merge(specific) |> prune_empty() |> reject_nil()
  end

  # BRANCH (BuildCteXml::taker): a role other than 4 names an existing party (toma3);
  # role 4 carries its own identification and address (toma4 + enderToma).
  defp toma_choice(%{"role" => 4} = t) do
    toma4 =
      %{
        toma: "4",
        x_nome: t["name"],
        x_fant: t["trade_name"],
        fone: t["phone"],
        email: t["email"]
      }
      |> Map.merge(tax_id(t))
      |> Map.put(:ie, t["state_registration"])
      |> Map.put(:ender_toma, t["address"] && address(t["address"]))
      |> reject_nil()

    %{toma4: toma4}
  end

  defp toma_choice(%{"role" => role}), do: %{toma3: %{toma: to_string(role)}}

  # MakeCTe::tagtoma4 (l.1235): CNPJ, else CPF.
  defp tax_id(%{"cnpj" => cnpj}) when cnpj not in [nil, ""], do: %{cnpj: cnpj}
  defp tax_id(%{"cpf" => cpf}) when cpf not in [nil, ""], do: %{cpf: cpf}
  defp tax_id(_), do: %{}

  # -- compl / emit / parties --------------------------------------------------------------

  # BuildCteXml::complement: the group exists only when `additional_info` is sent.
  defp compl(nil), do: nil

  defp compl(info) do
    reject_nil(%{
      x_obs: info["observations"],
      obs_cont:
        case info["contributor_fields"] do
          fields when fields in [nil, []] -> nil
          fields -> for f <- fields, do: %{x_campo: f["field"], x_texto: f["text"]}
        end
    })
  end

  defp emit(company) do
    reject_nil(%{
      cnpj: company["cnpj"],
      ie: company["state_registration"],
      x_nome: company["name"],
      x_fant: company["trade_name"],
      ender_emit:
        reject_nil(%{
          x_lgr: company["street"],
          nro: company["number"],
          x_cpl: company["complement"],
          x_bairro: company["district"],
          c_mun: company["city_ibge_code"],
          x_mun: company["city_name"],
          cep: company["zip_code"],
          uf: company["state"],
          fone: company["phone"]
        }),
      crt: company["tax_regime"]
    })
  end

  defp party(nil, _homolog?, _ender, _fant?), do: nil

  defp party(p, homolog?, ender, fant?) do
    %{
      ie: p["state_registration"],
      x_nome: party_name(p["name"], homolog?),
      x_fant: if(fant?, do: p["trade_name"]),
      fone: p["phone"],
      email: p["email"]
    }
    |> Map.merge(tax_id(p))
    |> Map.put(ender, address(p["address"]))
    |> reject_nil()
  end

  defp dest(r, homolog?) do
    r
    |> party(homolog?, :ender_dest, false)
    |> Map.put(:isuf, r["suframa_registration"])
    |> reject_nil()
  end

  defp party_name(_name, true), do: cut60(@homologation_name)
  defp party_name(name, false), do: cut60(name)
  defp cut60(name), do: name |> String.trim() |> String.slice(0, 60)

  defp address(a) do
    reject_nil(%{
      x_lgr: a["street"],
      nro: a["number"],
      x_cpl: a["complement"],
      x_bairro: a["district"],
      c_mun: a["city_ibge_code"],
      x_mun: a["city_name"],
      cep: a["zip_code"],
      uf: a["state"],
      c_pais: a["country_code"],
      x_pais: a["country_name"]
    })
  end

  # CT-e OS taker (BuildCteOsXml::taker): `tomador` is one flat call; the address is always sent.
  defp toma(t) do
    %{
      ie: t["state_registration"],
      x_nome: t["name"],
      x_fant: t["trade_name"],
      fone: t["phone"],
      email: t["email"],
      ender_toma: address(t["address"])
    }
    |> Map.merge(tax_id(t))
    |> reject_nil()
  end

  # -- vPrest / imp ------------------------------------------------------------------------

  defp v_prest(s) do
    reject_nil(%{
      v_t_prest: dec(s["total"], 2),
      v_rec: dec(s["receivable"], 2),
      comp:
        case s["components"] do
          comps when comps in [nil, []] -> nil
          comps -> for c <- comps, do: %{x_nome: c["name"], v_comp: dec(c["amount"], 2)}
        end
    })
  end

  defp imp(taxes, kind) do
    icms = taxes["icms"]
    reform = taxes["reform"]
    federal = taxes["federal"]

    reject_nil(%{
      icms: icms_choice(icms),
      v_tot_trib:
        if(positive?(icms["total_tax_estimate"]), do: dec(icms["total_tax_estimate"], 2)),
      inf_ad_fisco: icms["tax_authority_info"],
      inf_trib_fed: if(kind == :cte_os, do: federal(federal)),
      ibs_cbs: ibs_cbs(reform),
      v_tot_dfe: reform && dec(reform["total_document_amount"], 2)
    })
  end

  # BRANCH: see the header. Only the fields NFePHP writes for the CST, padded to 2 places.
  defp icms_choice(%{"simples_nacional" => true}), do: %{icms_sn: %{cst: "90", ind_sn: "1"}}

  defp icms_choice(i) do
    case i["cst"] do
      "00" ->
        %{icms00: tax_fields(i)}

      "20" ->
        %{icms20: Map.put(tax_fields(i), :p_red_bc, dec(i["base_reduction"], 2))}

      cst when cst in ["40", "41", "51"] ->
        %{icms45: %{cst: cst}}

      "60" ->
        %{
          icms60:
            reject_nil(%{
              cst: "60",
              v_bcst_ret: dec(i["st_base"], 2),
              v_icmsst_ret: dec(i["st_amount"], 2),
              p_icmsst_ret: dec(i["st_rate"], 2),
              v_cred: if(positive?(i["credit"]), do: dec(i["credit"], 2))
            })
        }

      "90" ->
        icms90(i)
    end
  end

  defp tax_fields(i) do
    %{
      cst: i["cst"],
      v_bc: dec(i["base"], 2),
      p_icms: dec(i["rate"], 2),
      v_icms: dec(i["amount"], 2)
    }
  end

  # outraUF is `$otherState !== null` (BuildCteXml::icms).
  defp icms90(%{"other_state" => o}) when is_map(o) do
    %{
      icms_outra_uf:
        reject_nil(%{
          cst: "90",
          p_red_bc_outra_uf: if(positive?(o["amount"]), do: dec(o["base_reduction"], 2)),
          v_bc_outra_uf: dec(o["base"], 2),
          p_icms_outra_uf: dec(o["rate"], 2),
          v_icms_outra_uf: dec(o["amount"], 2)
        })
    }
  end

  defp icms90(i) do
    %{
      icms90:
        reject_nil(%{
          cst: "90",
          p_red_bc: if(positive?(i["base_reduction"]), do: dec(i["base_reduction"], 2)),
          v_bc: dec(i["base"], 2),
          p_icms: dec(i["rate"], 2),
          v_icms: dec(i["amount"], 2),
          v_cred: if(positive?(i["credit"]), do: dec(i["credit"], 2))
        })
    }
  end

  defp federal(nil), do: nil

  defp federal(f) do
    %{
      v_pis: dec(f["pis_amount"], 2),
      v_cofins: dec(f["cofins_amount"], 2),
      v_ir: dec(f["income_tax_amount"], 2),
      v_inss: dec(f["inss_amount"], 2),
      v_csll: dec(f["csll_amount"], 2)
    }
    |> reject_nil()
  end

  defp ibs_cbs(nil), do: nil

  defp ibs_cbs(r) do
    g = r["ibs_cbs"] || %{}

    g_ibs_cbs =
      if g["base"] do
        # API REQUIREMENT: NFePHP computes vIBS = vIBSUF + vIBSMun when it is absent.
        v_ibs = g["ibs_amount"] || sum(g["state_amount"], g["municipal_amount"])

        reject_nil(%{
          v_bc: dec(g["base"], 2),
          g_ibs_uf: %{p_ibs_uf: dec(g["state_rate"], 4), v_ibs_uf: dec(g["state_amount"], 2)},
          g_ibs_mun: %{
            p_ibs_mun: dec(g["municipal_rate"], 2),
            v_ibs_mun: dec(g["municipal_amount"], 2)
          },
          v_ibs: dec(v_ibs, 2),
          g_cbs: %{p_cbs: dec(g["cbs_rate"], 4), v_cbs: dec(g["cbs_amount"], 2)},
          g_trib_regular: regular(r["regular"])
        })
      end

    reject_nil(%{
      cst: r["cst"],
      c_class_trib: r["classification"],
      ind_doacao: r["donation"],
      g_ibs_cbs: g_ibs_cbs
    })
  end

  defp sum(a, b) do
    Decimal.new(a || "0") |> Decimal.add(Decimal.new(b || "0")) |> Decimal.to_string(:normal)
  end

  defp regular(nil), do: nil

  defp regular(r) do
    %{
      cst_reg: r["cst"],
      c_class_trib_reg: r["classification"],
      p_aliq_efet_reg_ibs_uf: dec(r["state_rate"], 4),
      v_trib_reg_ibs_uf: dec(r["state_amount"], 2),
      p_aliq_efet_reg_ibs_mun: dec(r["municipal_rate"], 4),
      v_trib_reg_ibs_mun: dec(r["municipal_amount"], 2),
      p_aliq_efet_reg_cbs: dec(r["cbs_rate"], 4),
      v_trib_reg_cbs: dec(r["cbs_amount"], 2)
    }
  end

  # -- infCTeNorm (CT-e) -------------------------------------------------------------------

  defp inf_carga(c) do
    reject_nil(%{
      v_carga: dec(c["value"], 2),
      pro_pred: c["predominant_product"],
      x_out_cat: c["other_characteristics"],
      inf_q:
        for q <- c["quantities"] do
          %{c_unid: q["unit"], tp_med: q["measure"], q_carga: dec(q["quantity"], 4)}
        end,
      v_carga_averb: dec(c["insured_value"], 2)
    })
  end

  defp inf_doc(documents) do
    case documents["nfe"] do
      nfes when nfes in [nil, []] ->
        nil

      nfes ->
        %{
          inf_nfe:
            for(
              d <- nfes,
              do: reject_nil(%{chave: d["access_key"], d_prev: d["expected_delivery_date"]})
            )
        }
    end
  end

  # -- infCTeNorm (CT-e OS) ----------------------------------------------------------------

  defp inf_servico(s) do
    reject_nil(%{
      x_desc_serv: s["description"],
      inf_q: if(s["quantity"], do: %{q_carga: dec(s["quantity"], 4)})
    })
  end

  defp inf_doc_ref(nil), do: nil
  defp inf_doc_ref([]), do: nil

  defp inf_doc_ref(docs) do
    for d <- docs, do: doc_ref(d, d["bpe_access_key"])
  end

  defp doc_ref(d, key) when key in [nil, ""] do
    reject_nil(%{
      n_doc: d["number"],
      serie: d["series"],
      subserie: d["subseries"],
      d_emi: d["issue_date"],
      v_doc: dec(d["amount"], 2)
    })
  end

  defp doc_ref(_d, key), do: %{ch_bpe: key}

  defp seg(nil), do: nil
  defp seg([]), do: nil

  defp seg(items) do
    for s <- items do
      reject_nil(%{
        resp_seg: to_string(s["responsible"]),
        x_seg: s["insurer_name"],
        n_apol: s["policy_number"]
      })
    end
  end

  # BuildCteOsXml::road: tagrodo (TAF, else NroRegEstadual), tagveic, infFretamento.
  defp rodo_os(road) do
    taf = road["charter_authorization"]

    reject_nil(%{
      taf: if(taf not in [nil, ""], do: taf),
      nro_reg_estadual: if(taf in [nil, ""], do: road["state_registration_number"]),
      veic: veic(road["vehicle"]),
      inf_fretamento: fretamento(road["charter"])
    })
  end

  defp veic(nil), do: nil

  defp veic(v) do
    owner = v["owner"]

    reject_nil(%{
      placa: v["plate"],
      renavam: v["renavam"],
      prop: prop(owner),
      uf: v["state"]
    })
  end

  # MakeCTeOS::tagveic: `prop` only for a vehicle of a third party (owner with a name).
  defp prop(nil), do: nil

  defp prop(o) do
    if o["name"] in [nil, ""] do
      nil
    else
      taf = o["charter_authorization"]

      %{
        x_nome: o["name"],
        ie: o["state_registration"] && String.replace(o["state_registration"], ~r/\D/, ""),
        uf: o["state"],
        tp_prop: to_string(o["ownership_type"]),
        taf: if(taf not in [nil, ""], do: taf),
        nro_reg_estadual: if(taf in [nil, ""], do: o["state_registration_number"])
      }
      |> Map.merge(tax_id(o))
      |> reject_nil()
    end
  end

  defp fretamento(nil), do: nil

  defp fretamento(c) do
    reject_nil(%{tp_fretamento: to_string(c["type"]), dh_viagem: c["trip_at"]})
  end

  # `infPercurso` with no state is an empty list: the group is omitted.
  defp prune_empty(map) do
    map |> Enum.reject(fn {_k, v} -> v == [] end) |> Map.new()
  end
end
