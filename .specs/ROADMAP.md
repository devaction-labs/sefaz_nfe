# ROADMAP

Goal: be for Elixir what NFePHP (`sped-*`) is for PHP — the library a Brazilian
ERP reaches for to issue, receive and print fiscal documents — while keeping
what makes this one different: OTP-native, no runtime binaries, no tax engine.

The NFePHP map, and where each piece lands here:

| NFePHP | Role | Here |
|---|---|---|
| `sped-common` | certificate, signer, SOAP, C14N | done, inside `sefaz_nfe` (AD-026) |
| `sped-nfe` `Tools` | every NF-e webservice and event | Phase 1 |
| `sped-nfe` `Make` / `Complements` / `Standardize` | typed XML builder, `nfeProc`, XML → data | Phase 2 (AD-021) |
| `sped-nfe` NFC-e bits | model 65 transport; QR code, CSC, offline contingency | Phases 1 and 3 |
| `sped-da` | DANFE, DANFCE, DACCE, event PDFs | Phase 4, separate package |
| `sped-cte`, `sped-mdfe` | CT-e 57/67, MDF-e 58 | Phase 5, done in 0.4.0 (`SefazNfe.CTe`, `SefazNfe.MDFe`) |
| GNRE | state payment guides (not in NFePHP; the gateway's own client) | Phase 5b |
| `sped-nfcom`, `sped-bpe`, NFS-e | other models | Phase 6 |
| `sped-ibpt`, tax tables | tax arithmetic | **never** (AD-001) |

## Parity target: fiscal-gateway

Goal: do everything the maintainer's production PHP gateway `fiscal-gateway`
(Laravel on NFePHP `sped-nfe`/`sped-cte`/`sped-mdfe`/`sped-da`) does, except
tax calculation.

- NF-e 55: ✅ sync authorization · ✅ consult by key · ✅ status ·
  ✅ inutilização · ✅ cancel · ✅ CCe · ✅ DistDFe by ultNSU / single NSU /
  by key (download) · ✅ manifestação (4 events) · ✅ optional XSD.
- NF-e 55 parity gaps closed: ✅ cadastro consult · ✅ EPEC 110140 · ✅ SVC-AN /
  SVC-RS routing · ✅ certificate validity + tax id (issue #3) ·
  ✅ `cStat` classification incl. retryable/denied (issue #4).
- ✅ P2 Builder (0.3.0): `Make` coverage, data-driven from the PL, incl.
  IBS/CBS, IS, med, rastro, ICMSUFDest, DFeReferenciado, autXML, pag/detPag,
  fat/dup, transp/vol. ✅ P2 `Complements` toAuthorize / cancelRegister
  (`SefazNfe.Proc`) and `Standardize` (`Builder.parse_nfe/2`). Golden
  coverage still missing for ICMS 30/51/70/90, ISSQN and IBS/CBS
  regular/mono/seletivo.
- NFC-e 65: ✅ P1 endpoint routing + inutilização (moved earlier) ·
  ✅ P3 QR code version 3.00 (no CSC) · ✅ QR code 2.00 with CSC. Not used by the gateway: offline
  contingency (`tpEmis` 9), cancelamento por substituição.
- ⬜ P4 Printing: DANFE portrait with 8–21 installments and multiple `rastro`
  lots, EPEC and cancelled stamps; DANFCE 80mm; DACTE; DACTE OS; DAMDFE.
  DACCE and event PDFs are not used by the gateway.
- ✅ P5 CT-e 57/67 road modal (0.4.0): sync send, consult, status, cancel,
  structured CCe, comprovante de entrega 110180/110181, insucesso
  110190/110191, SVC-SP/SVC-RS, builder `MakeCTe`/`MakeCTeOS`. Live 100 is
  pending a credentialed emitter (reached 203 in homologação).
- ✅ P5 MDF-e 58 road (0.4.0): sync send, consult, status, não encerrados,
  cancel, encerramento 110112, inclusão de condutor 110114, inclusão de DF-e
  110115, builder. Lifecycle verified live in homologação.
- ⬜ P5b GNRE (see Phase 5b).
- Host-side, never in the library: tax engine (its `computed` mode), IBPT,
  CNPJá, automatic contingency policy (the library offers routes and the EPEC
  event; AD-005), numbering, idempotency, webhooks, tenancy, queues, storage,
  e-mail, `cStat` 656 parking policy, DistDFe cursor storage (AD-002),
  duplicate-key reconciliation.

Status legend: ✅ done · 🔜 next · ⬜ planned

## Phase 0 — close v0.1

- ✅ Full NF-e lifecycle verified in homologação on OTP 29.1.2 (STATE handoff).
- ✅ OTP-20327 handshake fix lands in 29.1; `patches/` removed (AD-020).
- ✅ 0.1.1 published to Hex.
- ⬜ Dependabot PRs still open.
- ⬜ Find why AN and SVAN homologação answer HTTP 403 to every client (with
  or without a client certificate) while production accepts the same A1.
  Neither host advertises client CA names in the initial handshake, which
  points at renegotiation or an allowlist. Until then, manifestação and
  DistDFe are verified in production only.

## Phase 1 — `Tools` parity for NF-e 55 (complete in 0.2.0, except the items below)

Every webservice and event a modelo 55 issuer or recipient can call. Items
the gateway uses come first.

- ✅ Certificate validity and tax id extraction (issue #3).
- ✅ `cStat` classification, including retryable and denied (issue #4).
- ✅ `NfeConsultaCadastro` (`CadConsultaCadastro4`) — consult a taxpayer's
  registration by CNPJ/CPF/IE per UF. Not every UF offers it; the endpoint
  table must say so.
- ✅ Contingency support, explicit, never automatic (AD-005, issue #5):
  EPEC (110140) and SVC-AN / SVC-RS endpoint routing selected by `tpEmis`.
- ✅ NFC-e 65 transport: model 65 endpoint routing and inutilização (QR code
  in Phase 3). NFC-e inutilização could not be verified live (SVRS and SP
  answer 998 Serviço Desativado).
- ✅ Telemetry per operation, UF and `cStat` (issue #6). Phase timings are not
  possible on the default `:httpc` transport and are documented as such.
- ✅ PKCS#12: security review of the in-tree reader; PBES2/AES-256 support so
  OpenSSL 3 exports load (AD-007 trade-off).
- ⬜ IBS/CBS events introduced by the reforma tributária NTs (NT 2025.002
  and successors) — inventory from the current NT before building.
- ⬜ Optional live conformance job in CI (manual dispatch, homologação,
  secrets held by the maintainer) running the lifecycle script.

Lower priority (not used by fiscal-gateway):

- ⬜ Ator interessado (110150).
- ⬜ Comprovante de entrega and its cancellation (110130/110131); insucesso
  de entrega and its cancellation (110192/110193, needs
  `hashTentativaEntrega` from NT 2021.002).
- ⬜ Conciliação financeira (110750/110751).
- ⬜ Pedido de prorrogação (111500/111501) and its cancellation.
- ⬜ Manifestação in batch (up to 20 events per `envEvento`).
- ⬜ Asynchronous multi-document lote, so `authorization_result/1` is
  exercised against a real receipt (AD-019 known gap).

## Phase 2 — build and read documents (complete in 0.3.0)

NFePHP's `Make` does not calculate taxes either: the caller passes every
value and `Make` puts it in schema order. AD-001 was amended for this
(AD-021).

- ✅ Typed builder for `infNFe` groups (ide, emit, dest, det/prod/imposto,
  total, transp, cobr, pag, infAdic, autXML, IBS/CBS groups), emitted in
  schema order, values passed through untouched. No totals are summed.
- ✅ Access key: `cNF` generation (NT 2019.001 rules), `cDV`, `Id`.
- ✅ `Complements`: `nfeProc` / `procEventoNFe` / `procInutNFe` assembly as
  public functions (today `authorize/1` does it internally).
- ✅ `Standardize`: parse any SEFAZ response or authorized document into
  plain maps/structs — the inverse of the builder.
- ✅ XSD validation shipped as a documented workflow per Pacote de
  Liberação (AD-015 stays: no vendored schemas). The builder validates
  XSD-equivalently from the generated layout (`mix sefaz.gen_layout`); tests
  that need the PL XSDs read `SEFAZ_NFE_PL_PATH` and skip without it.

## Phase 3 — NFC-e 65

Model 65 transport (endpoint routing, inutilização) is in Phase 1.

- ✅ QR code (v2 and the current version) with CSC/`idCSC`; version 3.00
  needs no CSC. `urlChave` table per UF as data (AD-004).
- ⬜ Cancelamento por substituição (110112).
- ⬜ Offline contingency (`tpEmis` 9) — signing and later transmission.

## Phase 4 — DANFE and friends (separate package)

The largest bet: a pure-Elixir PDF engine, Code 128C, QR code, plus the
gateway's DANFE customisations (installments, `rastro` lots). Golden-PDF
tests guard the layout.

- ⬜ `sefaz_da` (name TBD): DANFE (retrato/paisagem), DANFE simplificado,
  DANFCE (80mm/58mm), DACCE, event and inutilização printouts.
- ⬜ Input is an authorized XML; output is PDF bytes. No SEFAZ calls.
- ⬜ Pure Elixir, no external renderer (AD-023). Barcode (Code 128C for the
  key) and QR code generated in Elixir.

## Phase 5 — CT-e and MDF-e (complete in 0.4.0)

Unblocked by OTP 29.1 (AD-018). Research: `.specs/features/cte/research.md`.
Design: `.specs/features/cte-mdfe/design.md`. Issue #7. One package (AD-026).

- ✅ CT-e 57 and CT-e OS 67: authorization, consultation, status, SVC-SP/SVC-RS,
  events (cancelamento, CCe, comprovante de entrega, insucesso). EPEC is not
  covered. Live 100 needs a credentialed emitter.
- ✅ MDF-e 58: authorization, encerramento, cancelamento, inclusão de
  condutor / DF-e, consulta não encerrados.
- ⬜ DistDFe for CT-e on the Ambiente Nacional.

## Phase 5b — GNRE

SEFAZ-PE GNRE portal, the state payment guide.

- ⬜ SOAP 1.2 `GnreLoteRecepcao/processar` and `GnreResultadoLote/consultar`,
  lote XML v2.00.
- ⬜ Guide values are supplied by the caller; nothing is calculated.
- ⬜ Returns the linha digitável and barcode. Guide PDF is out of scope
  initially.
- ⬜ Added to `sefaz_nfe` as another module, or its own package if it grows (AD-026 keeps one package).

## Phase 6 — other models

- ⬜ NFCom 62 and BP-e 63 (same SOAP family, low marginal cost once the
  core is shared).
- ⬜ NFS-e padrão nacional (ADN): REST + JSON, not SOAP — probably its own
  package on top of the shared certificate/signing core.

## After Phase 2 — fiscal-gateway API in Elixir (separate project)

A new Phoenix application on top of this library, exposing the **same HTTP
contract** as `fiscal-gateway`, so a client migrates by pointing at another
domain. It is the **one central fiscal service** for every app (signetum and the
others): apps talk to it over HTTP and never depend on `sefaz_nfe` directly, so
certificates, numbering, SEFAZ connectivity and library upgrades live in one
place (decided 2026-11-23; issue #13 closed on that basis). The gateway's Scramble OpenAPI document (`/docs/api`) is the contract
and is checked by contract tests. Host-side concerns live there: numbering,
idempotency, webhooks (same HMAC and event names), tenancy, queues, storage,
e-mail, contingency policy. Open question: whether clients use the gateway's
`computed` tax mode — a tax engine is allowed in the app (AD-001 binds the
library only) but sizes the project.

Requirements found by the golden tests (T5, `test/support/gateway_payload.ex`
is the prototype mapping, 11 payloads equal to NFePHP's `infNFe`):

- Context outside the payload: company, series, number, cNF, `tpEmis` and the
  emission time come from the host, not from the request body.
- ICMS / PIS / COFINS / IPI branch selection by CST / CSOSN: the API maps the
  flat payload to the builder's branch key (`icms00`, `icms_sn102`, `pis_aliq`,
  ...).
- `vItem` and `vNFTot` are computed by NFePHP when IBS/CBS is present (the
  formula changes in 2027). The library never computes them, so the API must.
- NFePHP's free-text sanitisation of strings (not reproduced yet).
- Number padding per field (decimal places differ per NFePHP field), done by
  the API before calling the builder.

Requirements found by the CT-e / MDF-e golden tests (C6, 10 documents equal to
NFePHP's `infCte` / `infMDFe`):

- NFePHP computes `vIBS` when absent; the library never does, so the API must
  sum it.
- NFePHP computes MDF-e `qCTe` / `qNFe` by counting the documents; the API must
  count them.
- NFePHP's `number_format` rounds where the builder refuses a value with too
  many places; the API rounds before calling the builder, or surfaces the
  refusal.
- The gateway's `veic.owner` must require the IE when the state is sent: NFePHP
  emits an invalid `prop` otherwise and the builder refuses it.

## Open decisions

All three resolved by the maintainer on 2026-11-22.

- **D1** — resolved: AD-021. AD-001 amended; a structural builder is
  allowed, tax values and totals are still never computed.
- **D2** — resolved: AD-022, superseded by AD-026. One package, with
  `SefazNfe.CTe` and `SefazNfe.MDFe`; no `sefaz_core` extraction.
- **D3** — resolved: AD-023. DANFE family in pure Elixir, separate package;
  no headless browser, wkhtmltopdf, NIF or shell-out.
