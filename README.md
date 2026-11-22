# sefaz_nfe

Elixir library for **SEFAZ NF-e (modelo 55) and NFC-e (modelo 65) communication**: sign, authorize, consult, contingency, DistDFe.

It does **not** calculate taxes. The ERP (or Nexus Pro) builds the XML; this library talks to SEFAZ.

> Status: 0.2.0. Transport live and the whole NF-e lifecycle verified in
> homologação with a real ICP-Brasil A1: authorization (`cStat` 100, `nfeProc`
> assembled), CCe and cancellation (135), protocol consultation (100), and
> inutilização (102), all against SEFAZ BA. NFC-e 65 (authorize, consult, cancel
> with the generated QR code 3.00) and SVC-RS contingency were verified the same
> way. SVC-AN, EPEC, QR 2.00, NFC-e inutilização, DistDFe and manifestação could
> not be exercised in homologação; see the CHANGELOG.
>
> ```elixir
> {:sefaz_nfe, "~> 0.2.0"}
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

## What this is

```
ERP / Nexus  →  XML (cálculo ICMS, IBS/CBS, totais)
sefaz_nfe    →  A1, XMLDSig, SOAP 4.00, cStat, DistDFe
SEFAZ        →  autorização / rejeição / documentos distribuídos
```

Same split as Focus/ACBr: they guarantee **transport**, not fiscal arithmetic.

## Operating

- `mix sefaz.endpoints` audits the vendored endpoint table and prints the manual
  refresh procedure (AD-004). Wire it into CI: it fails on a snapshot older than
  180 days, on a UF missing an authorizer or IBGE code, and on any URL that is
  not an https `.gov.br` address.
- A UF that stops answering trips a circuit breaker after five consecutive
  transport failures and fails fast for 30 seconds, so a down SP cannot stall
  callers working with MG. A SEFAZ rejection is an answer and never trips it.

## Telemetry

Every public operation emits `[:sefaz_nfe, :operation, :start | :stop | :exception]`
with the operation, UF, environment, model, contingency and (on stop) the
outcome, `status` and `cStat`; the SOAP request and the per-UF circuit breaker
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
    tags: [:uf]
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
