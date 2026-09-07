# transport-mvp Context

**Gathered:** 2026-09-07  
**Spec:** `.specs/features/transport-mvp/spec.md`  
**Status:** Ready for design (assumptions logged; user can overrule)

---

## Feature Boundary

A **stateless Elixir Hex library** that signs and transports NF-e modelo 55 to SEFAZ (webservices 4.00) and pulls DistDFe from the Ambiente Nacional. No tax calculation, no DANFE, no Oban, no multi-tenant product.

---

## Implementation Decisions

### Split calculation vs communication

- Locked in conversation: ERP/Nexus builds XML; this lib only guarantees communication (same as Focus/ACBr).
- Nexus already has `NexusPro.Integrations.Acbr.Client` as the port this lib should be able to sit behind later.

### First customer / COGS

- Fabmed: ~2 000 pedidos/mês (peak 3 102 in 2026-05). Focus Growth ~R$ 548 / 4 000 notes / R$ 0,12 extra; **received** notes count.
- DistDFe is P1 because inbound XML is what blows the quota.

### Async / product-on-top

- Explicitly **later**. OTP (one DistDFe process per CNPJ, circuit breaker per UF) lives in Nexus or a future hub, not in v1 of the lib.

### Open source

- Public repo, community-facing, Apache-2.0 assumed.
- Do not Hex-publish until homologação `cStat` 100 exists.

### Agent's Discretion

- SOAP client (Req vs Mint+hackney), XML parser (`:xmerl` vs Saxy), exact module layout — Design.
- Snapshot of endpoint XML (nfephp `wsnfe_4.00_mod55.xml` is a **mirror**; official table is the portal).

### Declined / Undiscussed Gray Areas → Assumptions

See spec table: signature digest algorithm (read MOC at Execute), Fabmed UF, XSD-on-by-default in homolog, license Apache vs MIT.

---

## Specific References

- Focus Growth: R$ 548, 4 000 notes, R$ 0,12 from 4 001–10 000 ([focusnfe.com.br/precos](https://focusnfe.com.br/precos/simulador-growth/))
- Official services: [nfe.fazenda.gov.br/portal/webServices.aspx](https://www.nfe.fazenda.gov.br/portal/webServices.aspx)
- DistDFe produção: `https://www1.nfe.fazenda.gov.br/NFeDistribuicaoDFe/NFeDistribuicaoDFe.asmx`
- Hex today: `webmania_nfe` is a **WebmaniaBR API** client, not SEFAZ

---

## Deferred Ideas

- NFC-e, CT-e, DANFE, automatic SVC contingency, REST “Focus clone”, Hex package as a paid product
