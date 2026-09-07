# STATE

## Decisions

### AD-001
- **Decision**: This library performs SEFAZ **transport only** (sign, send, consult, DistDFe, events). It never computes ICMS, PIS, COFINS, IBS, CBS, DIFAL, or invoice totals.
- **Reason**: That arithmetic belongs to the ERP. Focus/ACBr already work this way. Duplicating NFePHP `Make` would make the lib a second tax engine and miss every Nota Técnica of the reforma.
- **Trade-off**: Callers must supply a schema-valid XML (or accept XSD rejection before SOAP).
- **Scope**: entire library
- **Date**: 2026-09-07
- **Status**: active

### AD-002
- **Decision**: The library is **stateless**. Callers persist `ultNSU` / `nSU`, `nNF`/`serie`, `nRec` (recibo), and certificates. No Ecto, no Oban inside the Hex package.
- **Reason**: OTP/async product (Nexus workers, one process per CNPJ) sits **on top** of the lib. Baking persistence in would fight every host app.
- **Trade-off**: DistDFe without a stored cursor is the caller's bug, not ours.
- **Scope**: entire library
- **Date**: 2026-09-07
- **Status**: active

### AD-003
- **Decision**: First production proof is **NF-e modelo 55**, one authorizing UF (the Fabmed issuer UF) + Ambiente Nacional DistDFe. NFC-e, CT-e, MDF-e, NFS-e are out of v1.
- **Reason**: Fabmed volume (≈2k orders/mês, DistDFe received notes) is the COGS problem. Extra models multiply endpoints and NTs.
- **Trade-off**: Not a drop-in Focus replacement on day one.
- **Scope**: v1 (`transport-mvp`)
- **Date**: 2026-09-07
- **Status**: active

### AD-004
- **Decision**: Endpoint URLs and XSD packages are **data**, refreshed from the official portal, not hardcoded as the source of truth.
- **Reason**: RFB/ENCAT change URLs and schemas (PL_010, CNPJ alfa, NT 2025.002). Shipping a stale table is a production outage.
- **Trade-off**: v1 may ship a snapshot of `webServices.aspx` + schema zip hash, with a documented refresh procedure.
- **Scope**: `SefazNfe.Endpoints`, `SefazNfe.Schema`
- **Date**: 2026-09-07
- **Status**: active

### AD-005
- **Decision**: Contingency (SVC-AN, SVC-RS, EPEC, FS-DA) is **not** automatic in v1. A down SEFAZ returns an error; the caller chooses contingency.
- **Reason**: Silent failover can duplicate authorization. MOC treats contingency as an explicit `tpEmis` change on the XML the ERP must rebuild.
- **Trade-off**: No "Focus-style" automatic contingency until a later feature.
- **Scope**: v1
- **Date**: 2026-09-07
- **Status**: active

## Handoff

- **Feature**: transport-mvp (`.specs/features/transport-mvp/`)
- **Phase / Task**: Specify + Design drafted; Execute not started
- **Completed**: repo scaffold, spec, context, design, wiki sources
- **In-progress**: none
- **Next step**: User confirms spec; then Tasks (`tasks.md`) then Execute (homologação with Fabmed A1)
- **Blockers**: none — waiting for spec confirmation
- **Uncommitted files**: initial commit
- **Branch**: main
