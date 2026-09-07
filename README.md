# sefaz_nfe

Elixir library for **SEFAZ NF-e communication** (modelo 55): sign, authorize, consult, DistDFe.

It does **not** calculate taxes. The ERP (or Nexus Pro) builds the XML; this library talks to SEFAZ.

> Status: spec only. No production emission yet. Homologação against a real CNPJ is the first proof.

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
