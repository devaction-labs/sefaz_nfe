# sefaz_nfe

Elixir library for **SEFAZ communication** for NF-e (55), NFC-e (65), CT-e (57/67) and MDF-e (58): build, sign, authorize, consult, events, contingency, DistDFe.

It does **not** calculate taxes. The ERP (or Nexus Pro) supplies every value; this library builds the XML from a map, signs it and talks to SEFAZ.

> Status: 0.4.0. CT-e 57/67 and MDF-e 58 transport, events and builder were added
> (see below and the CHANGELOG): MDF-e ran its whole lifecycle in homologação
> (authorize 100, condutor, encerramento 135, consult 132); CT-e reached SEFAZ
> validation (203, emitter not credentialed), so a CT-e 100 is still unverified.
> `service_status` answers 107 on 27/27 UFs for all three. NF-e transport live and the whole NF-e lifecycle verified in
> homologação with a real ICP-Brasil A1: authorization (`cStat` 100, `nfeProc`
> assembled), CCe and cancellation (135), protocol consultation (100), and
> inutilização (102), all against SEFAZ BA. NFC-e 65 (authorize, consult, cancel
> with the generated QR code 3.00) and SVC-RS contingency were verified the same
> way. SVC-AN, EPEC, QR 2.00, NFC-e inutilização, DistDFe and manifestação could
> not be exercised in homologação; see the CHANGELOG.
>
> ```elixir
> {:sefaz_nfe, "~> 0.4.0"}
> ```
>
> **Requires OTP 29.1 or later.** Earlier OTP 29 aborts the TLS handshake on
> 20 UFs (malformed CA names in `CertificateRequest`, fixed by OTP-20327). On
> OTP 29.1+ with the ICP-Brasil v10 root configured, `service_status/1` answers
> `cStat` 107 on 26 of 27 UFs. The exception is MA, which routes to SVAN and
> gets HTTP 403 from the server. The Ambiente Nacional and SVAN homologação
> endpoints also answer 403 ("You do not have permission to view this directory
> or page"), identically with curl/OpenSSL and the same certificate, so that is
> server-side. Ambiente Nacional production DistDFe answers normally.

## Package shell

Public API is in `SefazNfe` (`authorize/1`, `authorization_result/1`, `service_status/1`,
`dist_dfe/1`, `consult_protocol/1`, `consult_taxpayer/1`, `cancel/1`, `cce/1`,
`epec/1`, `manifest/2`, `void_numbers/1`, `start_dist_dfe_poller/1`).

`authorize/1` routes by the document's `<mod>` (55 or 65) and `tpEmis`. NFC-e
needs the QR code in `infNFeSupl`: `SefazNfe.NFCe.put_supl` builds it (3.00
on-line, or 2.00 with CSC). Contingency is explicit, never automatic: pass
`contingency:` to use SVC-AN or SVC-RS, or send an EPEC event with `epec/1`.

Input is validated and the UF URL is resolved from `priv/endpoints/nfe_4.00.json`.
All services run live over mTLS, with documents signed by XMLDSig. `mix test` never opens a socket —
`config/test.exs` swaps the transport for a stub.

### TLS trust anchors

Nearly every UF serves certificates chained to *Autoridade Certificadora Raiz
Brasileira v10*, which no OS bundle carries (measured: 24 of 27 UFs fail with
`{:tls, :unknown_ca}` without it; only GO and MG use commercial roots, as does
the Ambiente Nacional). Supply the roots rather than weakening verification:

```elixir
config :sefaz_nfe, :cacerts, "/etc/ssl/icp-brasil.pem"
```

Fetch them from the ITI repository and check the fingerprints before installing;
this library deliberately ships no trust anchors of its own (AD-009). The v10
root's SHA-256 fingerprint is:

```text
6E:0B:FF:06:9A:26:99:4C:15:DE:2C:48:88:CC:54:AF:84:88:2E:54:95:B7:FB:F6:6B:E9:CC:FF:EC:74:89:F6
```

Without them the call fails as `{:error, {:tls, :unknown_ca}}`, named so the cause is
obvious.

**A1 (PKCS#12) is real.** OTP 29 ships no PKCS#12 support and Hex has no package
for it, so `SefazNfe.Certificate.PKCS12` reads the PFX itself (RFC 7292),
verified byte-for-byte against a real ICP-Brasil A1 and against `openssl`.
`pbeWithSHAAnd3-KeyTripleDES-CBC` with a SHA-1 MAC — what ICP-Brasil issues
today — and PBES2/AES with SHA-256/512 MACs are supported. The reader is bounded
(size, bag count, iterations), checks that the key matches the leaf certificate,
and a wrong password is `{:error, :invalid_password}` (AD-007).

OTP (Elixir 1.20 / OTP 29): `Task.Supervisor` isolates SOAP, `Registry` + DistDFe **poller per `tax_id`** (`Process.set_label/1`), timeouts via `Duration` + `to_timeout/1`, `JSON` stdlib.

```elixir
# Decodes the PKCS#12: a wrong password fails here, on the MAC, not at SOAP.
{:ok, cert} = SefazNfe.Certificate.load(pfx_binary, "senha")
SefazNfe.service_status(%{cert: cert, uf: "SP", environment: :homologation})
# => {:ok, %SefazNfe.Result{c_stat: 107, x_motivo: "Serviço em Operação"}}

{:ok, url} = SefazNfe.Endpoints.url("SP", :homologation, :nfe_autorizacao)
```

### DistDFe poller

One labelled process per `tax_id` (CNPJ **or** CPF). The library never persists
the cursor — the required `:handler` receives each page and answers with the
cursor the host committed, so delivery is at-least-once:

```elixir
SefazNfe.start_dist_dfe_poller(
  tax_id: "00000000000191",
  cert: cert,
  ult_nsu: MyApp.load_cursor!(),
  handler: fn %SefazNfe.DistDFe{} = page ->
    :ok = MyApp.store(page.documents)
    {:ok, MyApp.commit_cursor!(page.ult_nsu)}
  end
)
```

## Building an NF-e

`SefazNfe.Builder.build_nfe/2` takes the content of `infNFe` as a map and
returns the unsigned XML and the access key. The layout is generated from the
Pacote de Liberação, so keys are the snake_case of the XSD names (`v_nf`,
`icms_sn102`, `det_pag`). Choices are picked by key, lists stand for repeated
elements, and `id`, `ide.c_nf` and `ide.c_dv` are generated when absent.

```elixir
nfe = %{
  ide: %{
    c_uf: 35, nat_op: "VENDA DE MERCADORIA", mod: 55, serie: 1, n_nf: 1,
    dh_emi: "2026-09-07T10:00:00-03:00", tp_nf: 1, id_dest: 1, c_mun_fg: 3_550_308,
    tp_imp: 1, tp_emis: 1, tp_amb: 2, fin_nfe: 1, ind_final: 1, ind_pres: 1,
    proc_emi: 0, ver_proc: "meu_erp 1.0"
  },
  emit: %{
    cnpj: "00000000000191", x_nome: "EMPRESA TESTE LTDA",
    ender_emit: %{
      x_lgr: "RUA TESTE", nro: "100", x_bairro: "CENTRO", c_mun: 3_550_308,
      x_mun: "SAO PAULO", uf: "SP", cep: "01001000", c_pais: 1058, x_pais: "BRASIL"
    },
    ie: "110042490114", crt: 1
  },
  det: [
    %{
      prod: %{
        c_prod: "001", c_ean: "SEM GTIN", x_prod: "PRODUTO TESTE", ncm: "84713012",
        cfop: 5102, u_com: "UN", q_com: "1.0000", v_un_com: "100.0000000000",
        v_prod: "100.00", c_ean_trib: "SEM GTIN", u_trib: "UN", q_trib: "1.0000",
        v_un_trib: "100.0000000000", ind_tot: 1
      },
      imposto: %{
        icms: %{icms_sn102: %{orig: 0, csosn: "102"}},
        pis: %{pis_nt: %{cst: "07"}},
        cofins: %{cofins_nt: %{cst: "07"}}
      }
    }
  ],
  total: %{
    icms_tot: %{
      v_bc: "0.00", v_icms: "0.00", v_icms_deson: "0.00", v_fcp: "0.00",
      v_bc_st: "0.00", v_st: "0.00", v_fcp_st: "0.00", v_fcp_st_ret: "0.00",
      v_prod: "100.00", v_frete: "0.00", v_seg: "0.00", v_desc: "0.00",
      v_ii: "0.00", v_ipi: "0.00", v_ipi_devol: "0.00", v_pis: "0.00",
      v_cofins: "0.00", v_outro: "0.00", v_nf: "100.00"
    }
  },
  transp: %{mod_frete: 9},
  pag: %{det_pag: [%{ind_pag: 0, t_pag: "01", v_pag: "100.00"}]}
}

{:ok, %{xml: xml, access_key: key}} = SefazNfe.Builder.build_nfe(nfe)

# Builds, signs (adding the QR code for model 65) and sends in one call:
{:ok, result} =
  SefazNfe.authorize(%{nfe: nfe, cert: cert, uf: "SP", environment: :homologation})

# The inverse: an NFe or nfeProc back to the same map shape.
{:ok, %{nfe: parsed, protocol: protocol}} = SefazNfe.Builder.parse_nfe(result.xml)
```

Errors are collected, not raised one at a time, each with its path:
`{:error, [{[:emit, :x_nome], :required}, {[:total, :icms_tot, :v_nf], {:pattern, "..."}}]}`.
From `authorize/1` they come as `{:error, {:invalid_nfe, errors}}`, before the
network. **The library never computes totals or taxes**: `v_nf`, `v_icms` and
every other value are passed through exactly as given (`Decimal` is accepted
when the optional dependency is present, and is formatted but never rounded).

The layout is data in `priv/layouts/nfe_4.00.etf`, generated from the official
Pacote de Liberação `PL_010h_v1.03` (NT 2026.005, 2026.006 and 2026.008,
published 13/11/2026 on the NF-e portal). To refresh it for a new PL, run
`mix sefaz.gen_layout` against the PL's `NFe/` directory. Tests that read the PL
XSDs use `SEFAZ_NFE_PL_PATH` (the `NFe/` directory of the unpacked PL) and skip
without it.

## CT-e and MDF-e

`SefazNfe.CTe` (models 57 and 67) and `SefazNfe.MDFe` (model 58) follow the same
shape as the NF-e API: a map built by `Builder.build_cte/2`, `build_cte_os/2` or
`build_mdfe/2` (or an XML), signed and sent in one call. Road modal only.

```elixir
{:ok, result} =
  SefazNfe.CTe.authorize(%{cte: cte, cert: cert, uf: "BA", environment: :homologation})

{:ok, result} =
  SefazNfe.MDFe.authorize(%{mdfe: mdfe, cert: cert, uf: "BA", environment: :homologation})

# Encerramento (110112); also cancel/1, include_driver/1, include_dfe/1, pending/1.
{:ok, closed} =
  SefazNfe.MDFe.close(%{
    cert: cert, uf: "BA", environment: :homologation, tax_id: "00000000000191",
    ch_mdfe: access_key, n_prot: result.n_prot, dt_enc: ~D[2026-11-22], c_uf: "29", c_mun: "2910800"
  })
```

CT-e also has `consult/1`, `cancel/1`, `cce/1`, `delivery_proof/1`,
`delivery_failure/1` and SVC-SP / SVC-RS contingency (`contingency:`).
`SefazNfe.CTe.Proc` and `SefazNfe.Proc` assemble the processed documents. The
tests that read the XSDs use `SEFAZ_NFE_CTE_PL_PATH` and `SEFAZ_NFE_MDFE_PL_PATH`.

## What this is

```
ERP / Nexus  →  valores (cálculo ICMS, IBS/CBS, totais)
sefaz_nfe    →  XML, A1, XMLDSig, SOAP 4.00, cStat, DistDFe
SEFAZ        →  autorização / rejeição / documentos distribuídos
```

Same split as Focus/ACBr: they guarantee **transport**, not fiscal arithmetic.

## Operating

- `mix sefaz.endpoints` audits the vendored endpoint table and prints the manual
  refresh procedure (AD-004). Wire it into CI: it fails on a snapshot older than
  180 days, on a UF missing an authorizer or IBGE code, and on any URL that is
  not an https `.gov.br` address.
- An authorizer host that stops answering trips a circuit breaker after five
  consecutive transport failures and fails fast for 30 seconds, so a down SP
  cannot stall callers working with MG. The breaker follows the server actually
  called, not the UF: BA's NF-e and BA's CT-e (via SVRS) are separate, and every
  UF routed to a down SVRS host fails fast together. A SEFAZ rejection is an
  answer and never trips it.

## Telemetry

Every public operation emits `[:sefaz_nfe, :operation, :start | :stop | :exception]`
with the operation, UF, environment, model, contingency and (on stop) the
outcome, `status` and `cStat`; the SOAP request and the per-host circuit breaker
emit their own events. Metadata never carries the certificate, CSC, XML, access
key or tax ids. `SefazNfe.Telemetry` documents every event and key; with
`Telemetry.Metrics` (or a PromEx plugin):

```elixir
import Telemetry.Metrics

[
  counter("sefaz_nfe.operation.count",
    event_name: [:sefaz_nfe, :operation, :stop],
    tags: [:operation, :uf, :outcome]
  ),
  distribution("sefaz_nfe.operation.duration",
    event_name: [:sefaz_nfe, :operation, :stop],
    measurement: :duration,
    unit: {:native, :millisecond},
    tags: [:operation, :uf]
  ),
  counter("sefaz_nfe.circuit_breaker.open.count",
    event_name: [:sefaz_nfe, :circuit_breaker, :open],
    tags: [:host]
  )
]
```

Only the total duration is available on the default `:httpc` transport: it does
not expose connect, transmit and response timings. A custom `SefazNfe.SOAP`
client can emit finer events.

## Docs

- Spec (TLC): [`.specs/features/transport-mvp/spec.md`](.specs/features/transport-mvp/spec.md)
- Design / SEFAZ services: [`.specs/features/transport-mvp/design.md`](.specs/features/transport-mvp/design.md)
- Wiki: [Home](https://github.com/devaction-labs/sefaz_nfe/wiki)

## Official sources

Endpoint table and schemas are **owned by the RFB / ENCAT**, not by this repo:

- [Portal NF-e — WebServices](https://www.nfe.fazenda.gov.br/portal/webServices.aspx)
- [Portal NF-e — Esquemas XML](https://www.nfe.fazenda.gov.br/portal/listaConteudo.aspx?tipoConteudo=BMPFMBoln3w=)
- DistDFe (Ambiente Nacional): `NFeDistribuicaoDFe` v1.00  
  Produção: `https://www1.nfe.fazenda.gov.br/NFeDistribuicaoDFe/NFeDistribuicaoDFe.asmx`

## License

Apache-2.0
