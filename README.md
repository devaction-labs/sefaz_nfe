# sefaz_nfe

Elixir library for **SEFAZ NF-e communication** (modelo 55): sign, authorize, consult, DistDFe.

It does **not** calculate taxes. The ERP (or Nexus Pro) builds the XML; this library talks to SEFAZ.

> Status: transport live, emission not yet. `service_status/1` is verified end to end
> against SEFAZ **SP, MT and MG** (`cStat` 107) over real mTLS with an ICP-Brasil A1.
> All eight services are live over mTLS. Against SEFAZ SP homologação, `authorize/1`
> gets past schema and signature validation and stops at `cStat` **245, CNPJ
> emitente não cadastrado** — no certificate or signature error was ever returned.
> A `cStat` 100 needs an emitter credenciado in that UF, which is registration
> data rather than code, and per the spec no Hex release happens before it.

## Package shell

Public API is in `SefazNfe` (`authorize/1`, `authorization_result/1`, `service_status/1`,
`dist_dfe/1`, `consult_protocol/1`, `cancel/1`, `cce/1`, `void_numbers/1`).

Input is validated and the UF URL is resolved from `priv/endpoints/nfe_4.00.json`.
`service_status/1` is live over mTLS; the services that need a signed document
stop at `Signer.sign_nfe/2` until XMLDSig lands. `mix test` never opens a socket —
`config/test.exs` swaps the transport for a stub.

### TLS trust anchors

SP and MT serve certificates chained to *Autoridade Certificadora Raiz
Brasileira v10*, which no OS bundle carries (MG and the Ambiente Nacional use
commercial roots and work as-is). Supply the roots rather than weakening
verification:

```elixir
config :sefaz_nfe, :cacerts, "/etc/ssl/icp-brasil.pem"
```

Fetch them from the ITI repository and check the fingerprints before installing;
this library deliberately ships no trust anchors of its own (AD-009). Without
them the call fails as `{:error, {:tls, :unknown_ca}}`, named so the cause is
obvious.

**A1 (PKCS#12) is real.** OTP 29 ships no PKCS#12 support and Hex has no package
for it, so `SefazNfe.Certificate.PKCS12` reads the PFX itself (RFC 7292),
verified byte-for-byte against a real ICP-Brasil A1 and against `openssl`.
`pbeWithSHAAnd3-KeyTripleDES-CBC` with a SHA-1 MAC — what ICP-Brasil issues
today — is supported; a PBES2/AES-256 file is refused by name, never as a
misleading "invalid password" (AD-007).

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
