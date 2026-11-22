defmodule SefazNfe.GatewayPayload do
  @moduledoc false
  # Test support: translates the NF-e request payload of the `fiscal-gateway` HTTP
  # contract (English snake_case, decoded JSON with string keys) into the input of
  # `SefazNfe.Builder.build_nfe/2` (AD-025). It is a PROTOTYPE of the mapping the
  # future Phoenix API needs, and it reproduces what the gateway's
  # `app/Pipelines/Nfe/BuildNfeXml.php` (gateway sha in test/golden/expected/GATEWAY_SHA)
  # does when it feeds NFePHP's `Make`. Three kinds of rule live here, and each is
  # marked so the API can lift them:
  #
  #   * NAMES    gateway field -> layout key (a plain rename).
  #   * BRANCH   the gateway's choice of the layout variant (the builder never infers
  #              one, AD-025): BuildNfeXml.php `icms/3` picks `tagICMSSN` when the
  #              payload has `csosn` and `tagICMS` otherwise; NFePHP then picks the
  #              `ICMSxx` element from the CST/CSOSN (Traits/TraitTagDetICMS.php
  #              `switch ($std->CST)` l.97 and `switch ($std->CSOSN)` l.1864), PIS and
  #              COFINS likewise (TraitTagDetPIS.php l.42, TraitTagDetCOFINS.php l.45),
  #              IPI (TraitTagDetIPI.php).
  #   * FORMAT   NFePHP pads every number to the places of its field
  #              (`conditionalNumberFormatting($v, 4)`: `pICMS` 4, `vUnCom` 10, `qCom` 4,
  #              money 2, ...), and the gateway passes its strings through. The builder
  #              writes a string as given, so the mapping pads (never rounds: more
  #              places than the field holds raises).
  #
  # `opts[:context]` is the part of the issuance the gateway keeps outside the payload
  # (`NfeIssuanceContext`: company, model, series, number, cNF, emission type,
  # environment, issue time), as the JSON in test/golden/contexts.

  alias SefazNfe.Layout

  @uf_codes %{
    "RO" => 11,
    "AC" => 12,
    "AM" => 13,
    "RR" => 14,
    "PA" => 15,
    "AP" => 16,
    "TO" => 17,
    "MA" => 21,
    "PI" => 22,
    "CE" => 23,
    "RN" => 24,
    "PB" => 25,
    "PE" => 26,
    "AL" => 27,
    "SE" => 28,
    "BA" => 29,
    "MG" => 31,
    "ES" => 32,
    "RJ" => 33,
    "SP" => 35,
    "PR" => 41,
    "SC" => 42,
    "RS" => 43,
    "MS" => 50,
    "MT" => 51,
    "GO" => 52,
    "DF" => 53
  }

  # Offsets of TimeZoneByUF::get (no daylight saving since 2019).
  @uf_offsets %{"AC" => -5, "AM" => -4, "RO" => -4, "RR" => -4, "MT" => -4, "MS" => -4}

  @homologation_name "NF-E EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL"
  @homologation_item "NOTA FISCAL EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL"
  @contingency_reason "SEFAZ de origem indisponivel"
  @zero "0.00"

  # BuildNfeXml.php NFCE_OPERATION: what model 65 allows.
  @nfce_operation %{tp_nf: 1, id_dest: 1, fin_nfe: 1, ind_final: 1, tp_imp: 4}

  @spec to_builder_map(map(), keyword()) :: map()
  def to_builder_map(payload, opts) do
    ctx = Keyword.fetch!(opts, :context)

    state = %{
      ctx: ctx,
      mod: ctx["model"],
      homolog?: ctx["environment"] == 2,
      # NFePHP Make.php l.857: `vItem` is written on every det once any item has IBS/CBS
      v_item?: Enum.any?(payload["items"], & &1["reform"])
    }

    %{
      ide: ide(payload, state),
      emit: emit(ctx["company"]),
      dest: dest(payload["recipient"], state),
      aut_xml: aut_xml(payload["authorized_parties"]),
      det: payload["items"] |> Enum.with_index(1) |> Enum.map(&det(&1, state)),
      total: total(payload["totals"], state, payload["items"]),
      cobr: cobr(payload["billing"]),
      transp: transp(payload["transport"] || %{"freight_mode" => 9}),
      pag: pag(payload["payments"], payload["change_amount"]),
      inf_adic: inf_adic(payload["additional_info"]),
      compra: compra(payload["purchase"])
    }
    |> reject_nil()
  end

  # -- ide / emit ------------------------------------------------------------

  defp ide(payload, %{ctx: ctx, mod: mod} = state) do
    ident = payload["identification"]
    company = ctx["company"]
    dh_emi = issued_at(ctx["issued_at"], company["state"])
    contingency? = ctx["emission_type"] in [4, 6, 7, 8]

    operation =
      if mod == 65 do
        @nfce_operation
      else
        %{
          tp_nf: ident["operation_type"],
          id_dest: ident["destination"],
          fin_nfe: ident["purpose"],
          ind_final: ident["final_consumer"],
          tp_imp: 1
        }
      end

    # NFePHP rejects a repeated key, and writes one NFref per refNFe
    refs = for ref <- ident["references"] || [], do: %{ref_nfe: ref["access_key"]}

    Map.merge(operation, %{
      c_uf: Map.fetch!(@uf_codes, company["state"]),
      c_nf: ctx["numeric_code"],
      nat_op: ident["operation_nature"],
      mod: mod,
      serie: ctx["series"],
      n_nf: ctx["number"],
      dh_emi: dh_emi,
      c_mun_fg: company["city_ibge_code"],
      tp_emis: ctx["emission_type"],
      tp_amb: ctx["environment"],
      ind_pres: ident["buyer_presence"],
      ind_intermed: ident["intermediary"],
      proc_emi: 0,
      ver_proc: "fiscal-gateway",
      dh_cont: if(contingency?, do: dh_emi),
      x_just: if(contingency?, do: @contingency_reason),
      nf_ref: if(refs != [], do: refs)
    })
    |> reject_nil()
    |> tap(fn _ -> state end)
  end

  # BuildNfeXml.php identification(): the issue time in the timezone of the company's UF.
  defp issued_at(text, uf) do
    {:ok, utc, _} = text |> String.replace(" ", "T", global: false) |> DateTime.from_iso8601()
    hours = Map.get(@uf_offsets, uf, -3)
    local = DateTime.add(utc, hours * 3600, :second)
    sign = if hours < 0, do: "-", else: "+"
    offset = "#{sign}#{pad(abs(hours))}:00"

    Calendar.strftime(local, "%Y-%m-%dT%H:%M:%S") <> offset
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp emit(company) do
    %{
      cnpj: company["cnpj"],
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
          uf: company["state"],
          cep: company["zip_code"],
          c_pais: 1058,
          x_pais: "Brasil",
          fone: company["phone"]
        }),
      # BuildNfeXml.php emitter(): `$company->state_registration ?? 'ISENTO'`
      ie: company["state_registration"] || "ISENTO",
      im: company["municipal_registration"],
      crt: company["tax_regime"]
    }
    |> reject_nil()
  end

  # -- dest ------------------------------------------------------------------

  defp dest(nil, _state), do: nil

  defp dest(recipient, %{mod: mod, homolog?: homolog?}) do
    ie = recipient["state_registration"]
    has_ie? = ie not in [nil, "", "ISENTO"]

    # NFePHP TraitTagDest::tagdest: a contributor without IE becomes "exempt" (2), an NFC-e
    # recipient is never a contributor, and homologation rewrites the name.
    ind_ie_dest =
      cond do
        mod == 65 -> 9
        recipient["state_registration_indicator"] == 1 and not has_ie? -> 2
        true -> recipient["state_registration_indicator"]
      end

    %{
      x_nome: dest_name(recipient["name"], mod, homolog?),
      ind_ie_dest: ind_ie_dest,
      ie: if(has_ie?, do: ie),
      isuf: recipient["suframa_registration"],
      im: recipient["municipal_registration"],
      email: recipient["email"],
      ender_dest: ender_dest(recipient["address"])
    }
    |> Map.merge(dest_id(recipient))
    |> reject_nil()
  end

  defp dest_name(name, _mod, true) when name not in [nil, ""], do: @homologation_name
  defp dest_name(_name, 65, true), do: @homologation_name
  defp dest_name(name, _mod, _homolog?), do: name

  # CNPJ, else CPF, else idEstrangeiro (TraitTagDest.php).
  defp dest_id(%{"cnpj" => cnpj}) when cnpj not in [nil, ""], do: %{cnpj: cnpj}
  defp dest_id(%{"cpf" => cpf}) when cpf not in [nil, ""], do: %{cpf: cpf}
  defp dest_id(%{"foreign_id" => id}) when id != nil, do: %{id_estrangeiro: id}
  defp dest_id(_), do: %{}

  defp ender_dest(nil), do: nil

  defp ender_dest(a) do
    reject_nil(%{
      x_lgr: a["street"],
      nro: a["number"],
      x_cpl: a["complement"],
      x_bairro: a["district"],
      c_mun: a["city_ibge_code"],
      x_mun: a["city_name"],
      uf: a["state"],
      cep: a["zip_code"],
      c_pais: a["country_code"],
      x_pais: a["country_name"],
      fone: a["phone"]
    })
  end

  defp aut_xml(nil), do: nil

  defp aut_xml(entries) do
    for e <- entries, do: reject_nil(%{cnpj: e["cnpj"], cpf: e["cpf"]})
  end

  # -- det -------------------------------------------------------------------

  defp det({item, number}, %{mod: mod, homolog?: homolog?} = state) do
    x_prod =
      if homolog? and mod == 65 and number == 1, do: @homologation_item, else: item["description"]

    prod =
      %{
        c_prod: item["code"],
        c_ean: item["gtin"] || "SEM GTIN",
        x_prod: x_prod,
        ncm: item["ncm"],
        cest: item["cest"],
        c_benef: item["benefit_code"],
        cfop: item["cfop"],
        u_com: item["commercial_unit"],
        q_com: dec(item["commercial_quantity"], 4),
        v_un_com: dec(item["commercial_unit_price"], 10),
        v_prod: dec(item["gross_amount"], 2),
        c_ean_trib: item["taxable_gtin"] || "SEM GTIN",
        u_trib: item["taxable_unit"],
        q_trib: dec(item["taxable_quantity"], 4),
        v_un_trib: dec(item["taxable_unit_price"], 10),
        v_frete: dec(item["freight"], 2),
        v_seg: dec(item["insurance"], 2),
        v_desc: dec(item["discount"], 2),
        v_outro: dec(item["other_expenses"], 2),
        ind_tot: Map.get(item, "counts_in_total", 1),
        x_ped: item["order_number"],
        n_item_ped: item["order_item_number"],
        rastro: rastro(item["traceability"]),
        med: medicine(item["medicine"])
      }
      |> reject_nil()

    imposto =
      reject_nil(%{
        v_tot_trib: dec(item["total_tax_estimate"], 2),
        icms: icms(item["icms"]),
        ipi: ipi(item["ipi"]),
        pis: pis_cofins(:pis, item["pis"]),
        cofins: pis_cofins(:cofins, item["cofins"]),
        icms_uf_dest: difal(item["difal"]),
        ibs_cbs: reform(item["reform"])
      })

    reject_nil(%{
      prod: prod,
      imposto: imposto,
      inf_ad_prod: item["additional_info"],
      v_item: if(state.v_item?, do: item |> v_item() |> money()),
      dfe_referenciado: referenced_document(item["referenced_document"])
    })
  end

  defp rastro(nil), do: nil
  defp rastro([]), do: nil

  defp rastro(lots) do
    for lot <- lots do
      reject_nil(%{
        n_lote: lot["lot"],
        q_lote: dec(lot["quantity"], 3),
        d_fab: lot["manufactured_on"],
        d_val: lot["expires_on"],
        c_agreg: lot["aggregation_code"]
      })
    end
  end

  defp medicine(nil), do: nil

  defp medicine(m) do
    reject_nil(%{
      c_prod_anvisa: m["anvisa_code"],
      x_motivo_isencao: m["exemption_reason"],
      v_pmc: dec(m["max_consumer_price"], 2)
    })
  end

  defp referenced_document(nil), do: nil

  defp referenced_document(d),
    do: %{chave_acesso: d["access_key"], n_item: d["item_number"]}

  # BRANCH. BuildNfeXml.php icms(): `csosn` present -> tagICMSSN, else tagICMS.
  @gateway_icms %{
    "origin" => :orig,
    "base_modality" => :mod_bc,
    "base_reduction" => :p_red_bc,
    "base" => :v_bc,
    "rate" => :p_icms,
    "amount" => :v_icms,
    "st_base_modality" => :mod_bc_st,
    "st_mva_rate" => :p_mva_st,
    "st_base_reduction" => :p_red_bc_st,
    "st_base" => :v_bc_st,
    "st_rate" => :p_icms_st,
    "st_amount" => :v_icms_st,
    "st_fcp_base" => :v_bc_fcp_st,
    "st_fcp_rate" => :p_fcp_st,
    "st_fcp_amount" => :v_fcp_st,
    "retained_st_base" => :v_bc_st_ret,
    "retained_st_rate" => :p_st,
    "substitute_amount" => :v_icms_substituto,
    "retained_st_amount" => :v_icms_st_ret,
    "retained_fcp_st_base" => :v_bc_fcp_st_ret,
    "retained_fcp_st_rate" => :p_fcp_st_ret,
    "retained_fcp_st_amount" => :v_fcp_st_ret,
    "effective_base_reduction" => :p_red_bc_efet,
    "effective_base" => :v_bc_efet,
    "effective_rate" => :p_icms_efet,
    "effective_amount" => :v_icms_efet,
    "sn_credit_rate" => :p_cred_sn,
    "sn_credit_amount" => :v_cred_icms_sn,
    "fcp_base" => :v_bc_fcp,
    "fcp_rate" => :p_fcp,
    "fcp_amount" => :v_fcp,
    "operation_amount" => :v_icms_op,
    "deferral_rate" => :p_dif,
    "deferred_amount" => :v_icms_dif,
    "exemption_amount" => :v_icms_deson,
    "exemption_reason" => :mot_des_icms,
    "deduct_exemption" => :ind_deduz_deson,
    "st_exemption_amount" => :v_icms_st_deson,
    "st_exemption_reason" => :mot_des_icms_st,
    "csosn" => :csosn,
    "cst" => :cst
  }

  # NFePHP TraitTagDetICMS.php, `switch ($std->CST)` (l.97).
  @cst_branch %{
    "00" => :icms00,
    "02" => :icms02,
    "10" => :icms10,
    "15" => :icms15,
    "20" => :icms20,
    "30" => :icms30,
    "40" => :icms40,
    "41" => :icms40,
    "50" => :icms40,
    "51" => :icms51,
    "53" => :icms53,
    "60" => :icms60,
    "61" => :icms61,
    "70" => :icms70,
    "90" => :icms90
  }

  # ... and `switch ($std->CSOSN)` (l.1864).
  @csosn_branch %{
    "101" => :icms_sn101,
    "102" => :icms_sn102,
    "103" => :icms_sn102,
    "300" => :icms_sn102,
    "400" => :icms_sn102,
    "201" => :icms_sn201,
    "202" => :icms_sn202,
    "203" => :icms_sn202,
    "500" => :icms_sn500,
    "900" => :icms_sn900
  }

  defp icms(icms) do
    branch =
      case icms do
        %{"csosn" => csosn} when csosn != nil -> Map.fetch!(@csosn_branch, csosn)
        %{"cst" => cst} -> Map.fetch!(@cst_branch, cst)
      end

    allowed = branch_keys(branch)

    fields =
      for {name, value} <- icms,
          key = Map.fetch!(@gateway_icms, name),
          key in allowed,
          value != nil,
          into: %{},
          do: {key, icms_value(key, value)}

    %{branch => fields}
  end

  # FORMAT: p* are percentages (4 places), v* amounts (2); the rest are codes.
  defp icms_value(key, value) do
    case Atom.to_string(key) do
      "p_" <> _ -> dec(value, 4)
      "v_" <> _ -> dec(value, 2)
      _ -> value
    end
  end

  defp branch_keys(branch) do
    layout = Layout.nfe()
    node = Layout.find(layout, [:inf_nfe, :det, :imposto, :icms, branch])
    Enum.map(Layout.elements(node), & &1.key)
  end

  # IPI: NFePHP TraitTagDetIPI.php: CST 00/49/50/99 -> IPITrib, any other -> IPINT.
  defp ipi(nil), do: nil

  defp ipi(ipi) do
    cst = ipi["cst"]

    inner =
      if cst in ["00", "49", "50", "99"] do
        %{
          ipi_trib:
            reject_nil(%{
              cst: cst,
              v_bc: dec(ipi["base"], 2),
              p_ipi: dec(ipi["rate"], 4),
              v_ipi: dec(ipi["amount"], 2)
            })
        }
      else
        %{ipi_nt: %{cst: cst}}
      end

    Map.put(inner, :c_enq, ipi["legal_framework_code"])
  end

  @pis_cofins_branch %{
    "pis_aliq" => :pis_aliq,
    "pis_qtde" => :pis_qtde,
    "pis_nt" => :pis_nt,
    "pis_outr" => :pis_outr,
    "cofins_aliq" => :cofins_aliq,
    "cofins_qtde" => :cofins_qtde,
    "cofins_nt" => :cofins_nt,
    "cofins_outr" => :cofins_outr
  }

  # PIS/COFINS: CST 01/02 -> Aliq, 03 -> Qtde, 04..09 -> NT, anything else -> Outr.
  defp pis_cofins(kind, tax) do
    cst = tax["cst"]
    k = Atom.to_string(kind)
    base = %{cst: cst}
    quantity? = tax["quantity"] != nil

    {branch, fields} =
      cond do
        cst in ["01", "02"] ->
          {"aliq", Map.merge(base, value_fields(kind, tax))}

        cst == "03" ->
          {"qtde", Map.merge(base, qty_fields(kind, tax))}

        cst in ~w(04 05 06 07 08 09) ->
          {"nt", base}

        quantity? ->
          {"outr", Map.merge(base, qty_fields(kind, tax))}

        true ->
          {"outr", Map.merge(base, value_fields(kind, tax))}
      end

    %{Map.fetch!(@pis_cofins_branch, "#{k}_#{branch}") => reject_nil(fields)}
  end

  defp value_fields(:pis, t),
    do: %{v_bc: dec(t["base"], 2), p_pis: dec(t["rate"], 4), v_pis: dec(t["amount"], 2)}

  defp value_fields(:cofins, t),
    do: %{v_bc: dec(t["base"], 2), p_cofins: dec(t["rate"], 4), v_cofins: dec(t["amount"], 2)}

  defp qty_fields(:pis, t),
    do: %{
      q_bc_prod: dec(t["quantity"], 4),
      v_aliq_prod: dec(t["unit_rate"], 4),
      v_pis: dec(t["amount"], 2)
    }

  defp qty_fields(:cofins, t),
    do: %{
      q_bc_prod: dec(t["quantity"], 4),
      v_aliq_prod: dec(t["unit_rate"], 4),
      v_cofins: dec(t["amount"], 2)
    }

  defp difal(nil), do: nil

  defp difal(d) do
    %{
      v_bc_uf_dest: dec(d["base"], 2),
      p_fcp_uf_dest: dec(d["fcp_rate"], 4),
      p_icms_uf_dest: dec(d["destination_rate"], 4),
      p_icms_inter: dec(d["interstate_rate"], 2),
      # NFePHP TraitTagDetICMS.php l.2411 writes the constant 100 and ignores the payload's
      # `destination_share` (the provisional partition ended in 2019)
      p_icms_inter_part: "100",
      v_fcp_uf_dest: dec(d["fcp_amount"], 2),
      v_icms_uf_dest: dec(d["destination_amount"], 2),
      v_icms_uf_remet: dec(d["origin_amount"], 2)
    }
  end

  # IBS/CBS. Only what the gateway's fixtures use; the `regular`, `monophasic` and
  # `selective_tax` groups are not mapped yet (and no golden payload carries them).
  defp reform(nil), do: nil

  defp reform(%{"regular" => _}), do: raise("reform.regular is not mapped")
  defp reform(%{"monophasic" => _}), do: raise("reform.monophasic is not mapped")
  defp reform(%{"selective_tax" => _}), do: raise("reform.selective_tax is not mapped")

  defp reform(reform) do
    g = reform["ibs_cbs"] || %{}

    %{
      cst: reform["cst"],
      c_class_trib: reform["classification"],
      g_ibs_cbs:
        reject_nil(%{
          v_bc: dec(g["base"] || "0", 2),
          g_ibs_uf:
            reject_nil(%{
              p_ibs_uf: dec(g["state_rate"] || "0", 4),
              g_red: reduction(g["state_reduction_rate"], g["state_effective_rate"]),
              v_ibs_uf: dec(g["state_amount"], 2)
            }),
          g_ibs_mun:
            reject_nil(%{
              # NFePHP TraitTagDetIBSCBS.php l.237: pIBSMun with the default 2 places
              p_ibs_mun: dec(g["municipal_rate"], 2),
              g_red: reduction(g["municipal_reduction_rate"], g["municipal_effective_rate"]),
              v_ibs_mun: dec(g["municipal_amount"], 2)
            }),
          v_ibs: dec(g["ibs_amount"], 2),
          g_cbs:
            reject_nil(%{
              p_cbs: dec(g["cbs_rate"], 4),
              g_red: reduction(g["cbs_reduction_rate"], g["cbs_effective_rate"]),
              v_cbs: dec(g["cbs_amount"], 2)
            })
        })
    }
  end

  defp reduction(nil, _), do: nil
  defp reduction(rate, eff), do: %{p_red_aliq: dec(rate, 4), p_aliq_efet: dec(eff || "0", 4)}

  # -- total -----------------------------------------------------------------

  # BuildNfeXml.php totals(): the zero defaults and the groups not accepted yet. NFePHP
  # TraitTagTotal.php::buildTagICMSTot omits vFCPUFDest, vICMSUFDest, vICMSUFRemet and
  # vTotTrib when they are not > 0, and writes the other fields with 2 places.
  defp total(t, state, items) do
    z = fn key -> dec(t[key] || @zero, 2) end

    omit_zero = fn key ->
      value = t[key] || @zero
      if positive?(value), do: dec(value, 2)
    end

    icms_tot =
      reject_nil(%{
        v_bc: dec(t["icms_base"], 2),
        v_icms: dec(t["icms_amount"], 2),
        v_icms_deson: z.("icms_exemption_amount"),
        v_fcp_uf_dest: omit_zero.("difal_fcp_amount"),
        v_icms_uf_dest: omit_zero.("difal_destination_amount"),
        v_icms_uf_remet: omit_zero.("difal_origin_amount"),
        v_fcp: z.("fcp_amount"),
        v_bc_st: z.("icms_st_base"),
        v_st: z.("icms_st_amount"),
        v_fcp_st: z.("fcp_st_amount"),
        v_fcp_st_ret: z.("retained_fcp_st_amount"),
        v_prod: dec(t["products_amount"], 2),
        v_frete: dec(t["freight_amount"], 2),
        v_seg: dec(t["insurance_amount"], 2),
        v_desc: dec(t["discount_amount"], 2),
        v_ii: dec(@zero, 2),
        v_ipi: dec(t["ipi_amount"], 2),
        v_ipi_devol: dec(@zero, 2),
        v_pis: dec(t["pis_amount"], 2),
        v_cofins: dec(t["cofins_amount"], 2),
        v_outro: dec(t["other_expenses_amount"], 2),
        v_nf: dec(t["document_amount"], 2),
        v_tot_trib: if(positive?(t["tax_estimate"]), do: dec(t["tax_estimate"], 2))
      })

    reject_nil(%{
      icms_tot: icms_tot,
      ibs_cbs_tot: ibs_cbs_tot(t["reform"]),
      v_nf_tot: if(t["reform"] && state.v_item?, do: v_nf_tot(items))
    })
  end

  # ARITHMETIC THE HOST OWNS (AD-021: the builder never computes). With IBS/CBS in the
  # document NFePHP writes `det/vItem` and `total/vNFTot` itself
  # (Traits/TraitCalculations.php::calculateTtensValues2 l.82-255, Make.php l.1306): the item
  # total before 2027 is vProd - vDesc - (vICMSDeson when indDeduzDeson = 1) + vICMSST +
  # vFCPST + vFrete + vSeg + vOutro + vIPI. From 2027 NFePHP also adds vIBS + vCBS + vIS
  # (it reads the clock, date('Y')), which this mapping does not do: the golden XML was
  # rendered in 2026.
  defp v_item(item) do
    icms = item["icms"]
    deduct = if icms["deduct_exemption"] == 1, do: d(icms["exemption_amount"]), else: d(nil)

    [d(item["gross_amount"]), d(item["freight"]), d(item["insurance"]), d(item["other_expenses"])]
    |> Enum.reduce(d(nil), &Decimal.add/2)
    |> Decimal.sub(d(item["discount"]))
    |> Decimal.sub(deduct)
    |> Decimal.add(d(icms["st_amount"]))
    |> Decimal.add(d(icms["st_fcp_amount"]))
    |> Decimal.add(d(get_in(item, ["ipi", "amount"])))
  end

  defp v_nf_tot(items) do
    sum =
      for item <- items, Map.get(item, "counts_in_total", 1) == 1, reduce: d(nil) do
        acc -> Decimal.add(acc, v_item(item))
      end

    if Decimal.compare(sum, 0) == :gt, do: money(sum)
  end

  defp d(nil), do: Decimal.new(0)
  defp d(value), do: Decimal.new(value)

  defp money(decimal), do: decimal |> Decimal.round(2) |> Decimal.to_string(:normal)

  defp positive?(nil), do: false
  defp positive?(value), do: Decimal.compare(Decimal.new(value), 0) == :gt

  defp ibs_cbs_tot(nil), do: nil

  defp ibs_cbs_tot(r) do
    z = dec(@zero, 2)

    %{
      v_bc_ibs_cbs: dec(r["base"], 2),
      g_ibs: %{
        g_ibs_uf: %{v_dif: z, v_dev_trib: z, v_ibs_uf: dec(r["state_ibs_amount"], 2)},
        g_ibs_mun: %{v_dif: z, v_dev_trib: z, v_ibs_mun: dec(r["municipal_ibs_amount"], 2)},
        v_ibs: dec(r["ibs_amount"], 2),
        v_cred_pres: z,
        v_cred_pres_cond_sus: z
      },
      g_cbs: %{
        v_dif: z,
        v_dev_trib: z,
        v_cbs: dec(r["cbs_amount"], 2),
        v_cred_pres: z,
        v_cred_pres_cond_sus: z
      },
      g_mono: %{
        v_ibs_mono: dec(r["monophasic_ibs_amount"] || @zero, 2),
        v_cbs_mono: dec(r["monophasic_cbs_amount"] || @zero, 2),
        v_ibs_mono_reten: z,
        v_cbs_mono_reten: z,
        v_ibs_mono_ret: z,
        v_cbs_mono_ret: z
      }
    }
  end

  # -- cobr / pag / transp / infAdic / compra --------------------------------

  defp cobr(nil), do: nil

  defp cobr(billing) do
    fat =
      if inv = billing["invoice"] do
        reject_nil(%{
          n_fat: inv["number"],
          v_orig: dec(inv["original_amount"], 2),
          v_desc: dec(inv["discount_amount"], 2),
          v_liq: dec(inv["net_amount"], 2)
        })
      end

    dup =
      for i <- billing["installments"] || [] do
        reject_nil(%{n_dup: i["number"], d_venc: i["due_date"], v_dup: dec(i["amount"], 2)})
      end

    reject_nil(%{fat: fat, dup: if(dup != [], do: dup)})
  end

  defp pag(payments, change) do
    det_pag =
      for p <- payments do
        card = p["card"] || %{}

        reject_nil(%{
          ind_pag: p["indicator"],
          t_pag: p["method"],
          x_pag: p["description"],
          v_pag: dec(p["amount"], 2),
          d_pag: p["date"],
          # NFePHP TraitTagPag.php: the card group only when tpIntegra is not empty
          card:
            if(card["integration_type"] not in [nil, ""],
              do:
                reject_nil(%{
                  tp_integra: card["integration_type"],
                  cnpj: card["acquirer_cnpj"],
                  t_band: card["brand"],
                  c_aut: card["authorization_code"],
                  cnpj_receb: card["beneficiary_cnpj"],
                  id_term_pag: card["terminal_id"]
                })
            )
        })
      end

    reject_nil(%{det_pag: det_pag, v_troco: dec(change, 2)})
  end

  defp transp(t) do
    carrier =
      if c = t["carrier"] do
        reject_nil(%{
          cnpj: c["cnpj"],
          cpf: if(c["cnpj"] == nil, do: c["cpf"]),
          x_nome: c["name"],
          ie: c["state_registration"],
          x_ender: c["address"],
          x_mun: c["city_name"],
          uf: c["state"]
        })
      end

    vol =
      for v <- t["volumes"] || [] do
        reject_nil(%{
          q_vol: v["quantity"] && dec(v["quantity"], 0),
          esp: v["species"],
          marca: v["brand"],
          n_vol: v["numbering"],
          peso_l: dec(v["net_weight"], 3),
          peso_b: dec(v["gross_weight"], 3)
        })
      end

    reject_nil(%{
      mod_frete: t["freight_mode"],
      transporta: carrier,
      vol: if(vol != [], do: vol)
    })
  end

  defp inf_adic(nil), do: nil

  defp inf_adic(info) do
    reject_nil(%{inf_ad_fisco: info["for_tax_authority"], inf_cpl: info["complementary"]})
  end

  defp compra(nil), do: nil

  defp compra(p) do
    reject_nil(%{
      x_n_emp: p["commitment_number"],
      x_ped: p["order_number"],
      x_cont: p["contract_number"]
    })
  end

  # -- helpers ---------------------------------------------------------------

  # FORMAT: pads a decimal string to `places` (NFePHP `number_format`), never rounds.
  defp dec(nil, _places), do: nil
  defp dec(value, places) when is_integer(value), do: dec(Integer.to_string(value), places)

  defp dec(value, places) when is_binary(value) do
    [int | frac] = String.split(value, ".", parts: 2)
    frac = List.first(frac, "")
    {kept, dropped} = String.split_at(frac, places)

    # number_format rounds; the mapping only drops zeros ("0.0000" -> "0.00")
    if String.trim(dropped, "0") != "" do
      raise ArgumentError,
            "#{inspect(value)} has more than #{places} places; the mapping never rounds"
    end

    case places do
      0 -> int
      _ -> int <> "." <> String.pad_trailing(kept, places, "0")
    end
  end

  defp reject_nil(map) when is_map(map) do
    map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  end
end
