# sefaz_nfe

Elixir library for **SEFAZ NF-e communication** (modelo 55): sign, authorize, consult, DistDFe.

It does **not** calculate taxes. The ERP (or Nexus Pro) builds the XML; this library talks to SEFAZ.

> Status: spec only. No production emission yet. Homologação against a real CNPJ is the first proof.

## Package shell

Public API is in `SefazNfe` (`authorize/1`, `ret_autorizacao/1`, `status_servico/1`,
`dist_dfe/1`, `consulta_protocolo/1`, `cancela/1`, `cce/1`, `inutiliza/1`).

Input is validated and the UF URL is resolved from `priv/endpoints/nfe_4.00.json`.
SOAP/XMLDSig still return `{:error, :not_implemented}` — no network in `mix test`.

OTP (Elixir 1.20 / OTP 29): `Task.Supervisor` isolates SOAP, `Registry` + DistDFe **poller per CNPJ** (`Process.set_label/1`), timeouts via `Duration` + `to_timeout/1`, `JSON` stdlib.

```elixir
{:ok, cert} = SefazNfe.Certificate.load(pfx_binary, "senha")
SefazNfe.status_servico(%{cert: cert, uf: "SP", ambiente: :homologacao})
# => {:error, :not_implemented}

{:ok, url} = SefazNfe.Endpoints.url("SP", :homologacao, :nfe_autorizacao)
```

## What this is

```
ERP / Nexus  →  XML (cálculo ICMS, IBS/CBS, totais)
sefaz_nfe    →  A1, XMLDSig, SOAP 4.00, cStat, DistDFe
SEFAZ        →  autorização / rejeição / documentos distribuídos
```

Same split as Focus/ACBr: they guarantee **transport**, not fiscal arithmetic.

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
