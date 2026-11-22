# cte-mdfe Design

**Roadmap**: Phase 5. **Decisions**: AD-026 (one package), AD-024/AD-025 (layout
and builder reused), AD-004 (endpoints as data), AD-005 (contingency explicit),
AD-001/AD-021 (no tax arithmetic). **Issue**: #7. **Research**:
`.specs/features/cte/research.md`.

**Parity target** (`fiscal-gateway`, road modal only):
- CT-e 57 and CT-e OS 67: synchronous send, consult, status, cancel, structured
  CC-e, comprovante de entrega 110180/110181, insucesso 110190/110191, SVC-SP /
  SVC-RS, builder (`MakeCTe` / `MakeCTeOS`).
- MDF-e 58: synchronous send, consult, status, cancel, encerramento 110112,
  inclusão de condutor 110114, inclusão de DF-e 110115, builder.

## What carries over unchanged

PKCS#12, mTLS, C14N, XMLDSig (`Signer.sign/4` already signs any `inf*` by Id),
SOAP 1.2 envelope and per-authorizer operations, circuit breaker, telemetry,
`Result`/`CStat` parsing, the layout generator, the builder and the parser.

## What is new

1. **Endpoints per model.** The authorizer is per model, not per state (BA
   issues NF-e itself and CT-e through SVRS; PE the reverse). New tables
   `priv/endpoints/cte_4.00.json` and `priv/endpoints/mdfe_3.00.json` with the
   same schema as the NF-e ones, audited by `mix sefaz.endpoints`. Source: the
   official CT-e portal (`cte.fazenda.gov.br/portal/webServices.aspx`, answers
   automated requests) and the MDF-e portal, cross-checked against NFePHP
   `wscte_4.00_mod57.xml`, `wscte_4.00_mod67.xml`, `wsmdfe_3.00.xml`.
   CT-e SVC: SVC-SP and SVC-RS (not SVC-AN).
2. **Layouts.** `mix sefaz.gen_layout` on `PL_CTe_400_RTC` (`TCTe`, `TCTeOS`)
   and `PL_MDFe_300b` (`TMDFe`). The generator may need idioms PL_010 did not
   use (`xs:any` for the modal, `xs:extension`); add them with tests rather than
   special-casing. The modal (`infModal`) is an `xs:any` wrapper whose content
   is validated against a separate modal XSD (`cteModalRodoviario`,
   `mdfeModalRodoviario`): generate the road modal layouts and let the builder
   embed them by `versaoModal`.
3. **Builder and key.** `Builder.build_cte/2`, `build_cte_os/2`,
   `build_mdfe/2`, `parse_*` — the same walker over a different root.
   `AccessKey` generalised: CT-e uses `cCT` and MDF-e `cMDF` with the same
   44-digit structure and DV.
4. **Transport.** `SefazNfe.CTe` and `SefazNfe.MDFe` facades mirroring
   `SefazNfe`: `authorize/1` (sync; CT-e 4.00 has no receipt step; the CT-e lot
   is gzip+base64 in `CTeRecepcaoSincV4` — verify in the MOC), `consult/1`,
   `service_status/1`, `cancel/1`, `cce/1` (structured corrections:
   `grupoAlterado`/`campoAlterado`/`valorAlterado`), CT-e delivery events,
   MDF-e `close/1` (encerramento), `include_driver/1`, `include_dfe/1`.
   Procs via `SefazNfe.Proc` (`cteProc`, `mdfeProc`, `procEventoCTe`,
   `procEventoMDFe`).

## Out of scope

CT-e Simplificado and GTV-e, non-road modals, MDF-e non-road, CT-e DistDFe,
DACTE/DAMDFE (Phase 4), tax arithmetic.

## Tasks

| # | Task | Done when |
|---|------|-----------|
| C1 | CT-e and MDF-e endpoint tables + routing by model (57, 67, 58) + audit | Live: `service_status` 107 on every CT-e authorizer and on MDF-e (SVRS) |
| C2 | Layouts for CT-e, CT-e OS, MDF-e and road modals; generator idioms | Regeneration byte-stable; trees asserted against the XSDs |
| C3 | Builder/parser/key for the three documents | xmllint-valid output; round trip; access keys verify |
| C4 | CT-e transport + events + procs | Live in homologação (BA via SVRS): authorize or a registration cStat that proves schema/signature; events where possible |
| C5 | MDF-e transport + events + procs | Live in homologação: authorize, encerramento, cancel where possible |
| C6 | Golden tests vs the gateway's `MakeCTe`/`MakeCTeOS`/`MDFe\\Make` | Canonical XML equal per payload or each difference explained |
