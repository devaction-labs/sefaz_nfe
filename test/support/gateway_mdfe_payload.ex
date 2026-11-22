defmodule SefazNfe.GatewayMdfePayload do
  @moduledoc false
  # Test support: translates the MDF-e (model 58) request payload of the `fiscal-gateway` HTTP
  # contract (English snake_case, decoded JSON with string keys) into the input of
  # `SefazNfe.Builder.build_mdfe/2`. A PROTOTYPE of the mapping the future Phoenix API needs; it
  # reproduces what the gateway's `app/Pipelines/Mdfe/BuildMdfeXml.php` (gateway sha in
  # test/golden/expected/GATEWAY_SHA) does when it feeds sped-mdfe's `Make`
  # (NFePHP/MDFe, vendor/nfephp-org/sped-mdfe/src/Make.php).
  #
  #   * NAMES    gateway field -> layout key (a plain rename).
  #   * BRANCH   BuildMdfeXml.php always writes the road modal: `infANTT` (RNTRC only, `road/2`),
  #              `veicTracao` with its drivers, `prodPred` and `tot`; no `veicReboque`, `lacRodo`,
  #              `seg`, `lacres` or `infAdic` exists in the gateway contract, so none is mapped.
  #   * FORMAT   `tot.vCarga` is padded to 2 places and `tot.qCarga` to 4
  #              (`conditionalNumberFormatting`, Make.php l.1887-1960,
  #              `SefazNfe.GatewayCommon.dec/2`); the vehicle numbers (`tara`, `capKG`, `capM3`)
  #              are written as given (l.2700-2740).
  #
  # NFePHP-side behaviours reproduced here (never in lib):
  #
  #   * `cMDF` is the random code of the key (BuildMdfeXml.php `handle/2`: `Keys::random()`):
  #     the context's `numeric_code`; `cDV` is the one the builder computes (Make::monta()'s
  #     `checkMDFKey()` rewrites the placeholder `0` the gateway passes).
  #   * `dhEmi` is the context's issue time as given (BuildMdfeXml.php `identification/3` does NOT
  #     convert it to the company's UF, unlike CT-e).
  #   * Make::monta() inserts every `infMunCarrega` right after `UFFim` one by one
  #     (`insertAfter`, Make.php l.2109), so the loading municipalities come out in REVERSE order.
  #     The order of those repeated siblings is not significant to the schema; the mapping reverses
  #     the list so both documents canonicalise alike.
  #   * `infRespTec` is written only when `config('fiscal.mdfe.responsible_technical.cnpj')` is
  #     set (BuildMdfeXml.php `technicalContact/1`); in the gateway that is env
  #     `MDFE_RESP_TEC_*`, here the context's optional `responsible_technical`.
  #   * `emit` carries `xFant` only when the company has a trade name, and `enderEmit` the company
  #     e-mail (unlike the CT-e, which has none).
  #
  # API REQUIREMENTS found while writing this (what the HTTP API must do for the host):
  #
  #   * NFePHP computes `tot/qCTe` and `tot/qNFe` as the number of `infCTe` / `infNFe` in the
  #     whole document (Make::tagtot, l.1898-1922; an empty count is omitted). The builder does no
  #     arithmetic, so the API must count them (`q_cte`, `q_nfe`). Note NFePHP's own validation
  #     refuses a single document for emitter types 1 and 3 without `infLotacao` (Make::monta);
  #     the gateway has no `infLotacao`, so such a payload fails there, not in the builder.
  #   * `ide.c_dv` and `Id` come from the builder's key; `number_format` rounds, the mapping pads
  #     only, so a client value with more places than the field must be rejected by the API.
  #
  # `opts[:context]` is the part of the issuance the gateway keeps outside the payload
  # (`MdfeIssuanceContext`: company, model, series, number, cMDF, emission type, environment,
  # issue time, and the technical contact from the app configuration), as the JSON in
  # test/golden/contexts.

  import SefazNfe.GatewayCommon

  @spec to_builder_map(map(), keyword()) :: map()
  def to_builder_map(p, opts) do
    ctx = Keyword.fetch!(opts, :context)
    company = ctx["company"]

    %{
      ide: ide(p["identification"], ctx),
      emit: emit(company),
      inf_modal: %{
        versao_modal: "3.00",
        rodo: %{
          inf_antt: %{rntrc: p["road"]["rntrc"]},
          veic_tracao: veic_tracao(p["vehicle"], p["drivers"])
        }
      },
      inf_doc: %{inf_mun_descarga: p["documents"] |> Enum.map(&mun_descarga/1)},
      prod_pred: %{tp_carga: p["cargo"]["type"], x_prod: p["cargo"]["predominant_product"]},
      tot: tot(p),
      inf_resp_tec: resp_tec(ctx["responsible_technical"])
    }
    |> reject_nil()
  end

  defp ide(i, ctx) do
    company = ctx["company"]

    reject_nil(%{
      c_uf: uf_code(company["state"]),
      tp_amb: ctx["environment"],
      tp_emit: i["emitter_type"],
      mod: ctx["model"],
      serie: ctx["series"],
      n_mdf: ctx["number"],
      c_mdf: ctx["numeric_code"],
      modal: "1",
      dh_emi: iso(ctx["issued_at"]),
      tp_emis: ctx["emission_type"],
      proc_emi: 0,
      ver_proc: "fiscal-gateway",
      uf_ini: i["start_state"],
      uf_fim: i["end_state"],
      inf_mun_carrega:
        i["loading_municipalities"]
        |> Enum.map(&%{c_mun_carrega: &1["city_ibge_code"], x_mun_carrega: &1["city_name"]})
        |> Enum.reverse(),
      dh_ini_viagem: i["planned_trip_start_at"]
    })
  end

  # `$context->issuedAt->format('Y-m-d\TH:i:sP')`: the offset of the input is kept.
  defp iso(text) do
    {:ok, dt, offset} = text |> String.replace(" ", "T", global: false) |> DateTime.from_iso8601()
    local = DateTime.add(dt, offset, :second)
    sign = if offset < 0, do: "-", else: "+"
    abs_min = div(abs(offset), 60)

    Calendar.strftime(local, "%Y-%m-%dT%H:%M:%S") <>
      "#{sign}#{pad2(div(abs_min, 60))}:#{pad2(rem(abs_min, 60))}"
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

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
          fone: company["phone"],
          email: company["email"]
        })
    })
  end

  defp veic_tracao(v, drivers) do
    reject_nil(%{
      placa: v["plate"],
      renavam: v["renavam"],
      tara: v["tare_weight"],
      cap_kg: v["capacity_kg"],
      cap_m3: v["capacity_m3"],
      condutor: for(d <- drivers, do: %{x_nome: d["name"], cpf: d["cpf"]}),
      tp_rod: v["axle_type"],
      tp_car: v["body_type"],
      uf: v["state"]
    })
  end

  # One infMunDescarga per group with its infCTe / infNFe (BuildMdfeXml::documents).
  defp mun_descarga(group) do
    reject_nil(%{
      c_mun_descarga: group["city_ibge_code"],
      x_mun_descarga: group["city_name"],
      inf_cte: keys(group["cte_keys"], :ch_cte),
      inf_nfe: keys(group["nfe_keys"], :ch_nfe)
    })
  end

  defp keys(nil, _tag), do: nil
  defp keys([], _tag), do: nil
  defp keys(list, tag), do: for(key <- list, do: %{tag => key})

  # API REQUIREMENT: qCTe and qNFe are counted by NFePHP over the whole document.
  defp tot(p) do
    docs = p["documents"]
    count = fn field -> docs |> Enum.map(&length(&1[field] || [])) |> Enum.sum() end
    cargo = p["cargo"]

    reject_nil(%{
      q_cte: positive_count(count.("cte_keys")),
      q_nfe: positive_count(count.("nfe_keys")),
      v_carga: dec(cargo["total_value"], 2),
      c_unid: cargo["unit"],
      q_carga: dec(cargo["quantity"], 4)
    })
  end

  defp positive_count(0), do: nil
  defp positive_count(n), do: Integer.to_string(n)

  # BuildMdfeXml::technicalContact: only when the configured CNPJ is set.
  defp resp_tec(nil), do: nil
  defp resp_tec(%{"cnpj" => nil}), do: nil

  defp resp_tec(r) do
    %{cnpj: r["cnpj"], x_contato: r["contact_name"], email: r["email"], fone: r["phone"]}
  end
end
