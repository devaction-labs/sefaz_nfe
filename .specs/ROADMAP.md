# ROADMAP

Goal: be for Elixir what NFePHP (`sped-*`) is for PHP — the library a Brazilian
ERP reaches for to issue, receive and print fiscal documents — while keeping
what makes this one different: OTP-native, no runtime binaries, no tax engine.

The NFePHP map, and where each piece lands here:

| NFePHP | Role | Here |
|---|---|---|
| `sped-common` | certificate, signer, SOAP, C14N | done, inside `sefaz_nfe` (AD-022) |
| `sped-nfe` `Tools` | every NF-e webservice and event | Phase 1 |
| `sped-nfe` `Make` / `Complements` / `Standardize` | typed XML builder, `nfeProc`, XML → data | Phase 2 (AD-021) |
| `sped-nfe` NFC-e bits | QR code, CSC, offline contingency | Phase 3 |
| `sped-da` | DANFE, DANFCE, DACCE, event PDFs | Phase 4, separate package |
| `sped-cte`, `sped-mdfe` | CT-e 57/67, MDF-e 58 | Phase 5 |
| `sped-nfcom`, `sped-bpe`, NFS-e | other models | Phase 6 |
| `sped-ibpt`, tax tables | tax arithmetic | **never** (AD-001) |

Status legend: ✅ done · 🔜 next · ⬜ planned

## Phase 0 — close v0.1 (now)

- ✅ Full NF-e lifecycle verified in homologação on OTP 29.1.2 (STATE handoff).
- ✅ OTP-20327 handshake fix lands in 29.1; `patches/` removed (AD-020).
- 🔜 Merge `chore/otp-29-1-live-check`; publish 0.1.1 to Hex (issue #13).
- 🔜 Close the delivered issues #1–#4; triage the dependabot PRs.
- ⬜ Find why AN and SVAN homologação answer HTTP 403 to every client (with
  or without a client certificate) while production accepts the same A1.
  Neither host advertises client CA names in the initial handshake, which
  points at renegotiation or an allowlist. Until then, manifestação and
  DistDFe are verified in production only.

## Phase 1 — `Tools` parity for NF-e 55

Every webservice and event a modelo 55 issuer or recipient can call.

- ⬜ `NfeConsultaCadastro` (`CadConsultaCadastro4`) — consult a taxpayer's
  registration by CNPJ/CPF/IE per UF. Not every UF offers it; the endpoint
  table must say so.
- ⬜ Asynchronous multi-document lote, so `authorization_result/1` is
  exercised against a real receipt (AD-019 known gap).
- ⬜ Manifestação in batch (up to 20 events per `envEvento`).
- ⬜ Remaining events: EPEC (110140), ator interessado (110150), comprovante
  de entrega and its cancellation (110130/110131), insucesso de entrega and
  its cancellation (110192/110193, needs `hashTentativaEntrega` from
  NT 2021.002), conciliação financeira (110750/110751), pedido de
  prorrogação (111500/111501) and its cancellation.
- ⬜ IBS/CBS events introduced by the reforma tributária NTs (NT 2025.002
  and successors) — inventory from the current NT before building.
- ⬜ Contingency support, explicit, never automatic (AD-005, issue #5):
  SVC-AN / SVC-RS endpoint routing selected by `tpEmis`, plus the EPEC flow.
- ⬜ Telemetry per operation, UF and `cStat` (issue #6).
- ⬜ PKCS#12: security review of the in-tree reader; PBES2/AES-256 support so
  OpenSSL 3 exports load (AD-007 trade-off).
- ⬜ Optional live conformance job in CI (manual dispatch, homologação,
  secrets held by the maintainer) running the lifecycle script.

## Phase 2 — build and read documents

NFePHP's `Make` does not calculate taxes either: the caller passes every
value and `Make` puts it in schema order. AD-001 was amended for this
(AD-021).

- ⬜ Typed builder for `infNFe` groups (ide, emit, dest, det/prod/imposto,
  total, transp, cobr, pag, infAdic, autXML, IBS/CBS groups), emitted in
  schema order, values passed through untouched. No totals are summed.
- ⬜ Access key: `cNF` generation (NT 2019.001 rules), `cDV`, `Id`.
- ⬜ `Complements`: `nfeProc` / `procEventoNFe` / `procInutNFe` assembly as
  public functions (today `authorize/1` does it internally).
- ⬜ `Standardize`: parse any SEFAZ response or authorized document into
  plain maps/structs — the inverse of the builder.
- ⬜ XSD validation shipped as a documented workflow per Pacote de
  Liberação (AD-015 stays: no vendored schemas).

## Phase 3 — NFC-e 65

- ⬜ Model 65 routing in the endpoint table (different URLs per UF).
- ⬜ QR code (v2 and the current version) with CSC/`idCSC`; `urlChave`
  table per UF as data (AD-004).
- ⬜ Cancelamento por substituição (110112).
- ⬜ Offline contingency (`tpEmis` 9) — signing and later transmission.

## Phase 4 — DANFE and friends (separate package)

- ⬜ `sefaz_da` (name TBD): DANFE (retrato/paisagem), DANFE simplificado,
  DANFCE (80mm/58mm), DACCE, event and inutilização printouts.
- ⬜ Input is an authorized XML; output is PDF bytes. No SEFAZ calls.
- ⬜ Pure Elixir, no external renderer (AD-023). Barcode (Code 128C for the
  key) and QR code generated in Elixir.

## Phase 5 — CT-e and MDF-e

Unblocked by OTP 29.1 (AD-018). Research: `.specs/features/cte/research.md`.
Issue #7.

- ⬜ CT-e 57 and CT-e OS 67: authorization, consultation, events
  (cancelamento, CCe, EPEC, comprovante de entrega, insucesso).
- ⬜ MDF-e 58: authorization, encerramento, cancelamento, inclusão de
  condutor / DF-e, consulta não encerrados.
- ⬜ DistDFe for CT-e on the Ambiente Nacional.

## Phase 6 — other models

- ⬜ NFCom 62 and BP-e 63 (same SOAP family, low marginal cost once the
  core is shared).
- ⬜ NFS-e padrão nacional (ADN): REST + JSON, not SOAP — probably its own
  package on top of the shared certificate/signing core.

## Open decisions

All three resolved by the maintainer on 2026-11-22.

- **D1** — resolved: AD-021. AD-001 amended; a structural builder is
  allowed, tax values and totals are still never computed.
- **D2** — resolved: AD-022. One package until Phase 5, then extract
  `sefaz_core` and publish `sefaz_nfe`, `sefaz_cte`, `sefaz_mdfe` on top.
- **D3** — resolved: AD-023. DANFE family in pure Elixir, separate package;
  no headless browser, wkhtmltopdf, NIF or shell-out.
