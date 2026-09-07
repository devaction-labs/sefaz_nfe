# SEFAZ transport MVP Specification

## Problem Statement

Phoenix/Elixir apps that emit NF-e in Brazil (Nexus Pro, others) pay a per-document API (Focus, ACBr) for **SOAP + A1 + DistDFe**. Hex has no library that talks to SEFAZ; only SDKs of paid APIs (`webmania_nfe`). A distributor like Fabmed (~2 000 pedidos/mês, peak 3 102, plus **received** NF-e on the same quota) makes that COGS scale with the client's volume, not with our software.

This feature is a **stateless Elixir library**: take an XML the ERP already built, sign it, send it, return `cStat` / protocol / distributed documents. Tax calculation stays in the ERP.

## Goals

- [ ] Authorize a modelo 55 NF-e in **homologação** against one real CNPJ (Fabmed UF) using only this library + an ERP-supplied XML
- [ ] Poll DistDFe by NSU and return documents without counting them as a paid "note" to a third party
- [ ] Never compute or rewrite tax groups (ICMS, IBS/CBS, totals)
- [ ] Publish the contract so Nexus can swap `Acbr.Client` for `SefazNfe` behind the same port

## Out of Scope

| Feature | Reason |
| --- | --- |
| Building NF-e XML / tax calculation (`Make`) | ERP / Nexus fiscal engine. AD-001 |
| NFC-e (65), CT-e, MDF-e, NFS-e, NFCom | Different endpoints and NTs. AD-003 |
| Automatic contingency (SVC-AN/RS, EPEC, FS-DA) | Requires ERP to rebuild XML with new `tpEmis`. AD-005 |
| DANFE PDF | Presentation; ACBr/sped-da can stay for v1 |
| Ecto, Oban, multi-tenant product | Host app (Nexus). AD-002 |
| CadConsultaCadastro, downloadNF legacy | Not needed to stop Focus COGS for Fabmed |
| Focus/ACBr-compatible REST API | Later product on top of this lib |
| Hex publish before one authorized homologação NF-e | Proof first |

---

## Assumptions & Open Questions

| Assumption / decision | Chosen default | Rationale | Confirmed? |
| --- | --- | --- | --- |
| Layout | NF-e 4.00 webservices (`NFeAutorizacao4`, …). XML may carry PL_009 or PL_010 (IBS/CBS) groups; we **transmit** them, we do not fill them | Official portal lists version **4.00** for authorization services as of 2026 | y — [webServices.aspx](https://www.nfe.fazenda.gov.br/portal/webServices.aspx) |
| DistDFe | Ambiente Nacional, service **NFeDistribuicaoDFe** v**1.00** | Same portal, AN block; produção `https://www1.nfe.fazenda.gov.br/NFeDistribuicaoDFe/NFeDistribuicaoDFe.asmx` | y — portal snippet 2026-09-07 |
| Signature | XMLDSig enveloped on `infNFe` / events as MOC 4.00; A1 PFX (PKCS#12) | ICP-Brasil A1 is what Focus/ACBr already use in Nexus | n — exact digest algorithm must match current MOC when implementing; do not guess SHA-1 vs SHA-256 at Execute time, read the MOC annex |
| TLS | Client certificate from the same A1 on every SOAP call | SEFAZ requires mTLS | y — MOC / all existing stacks |
| Library persistence | None. `ultNSU` is an argument | AD-002 | y — conversation |
| First UF | Whatever UF the Fabmed **issuer** is registered in; DistDFe is AN (national) | Authorization is per-UF; distribution is AN | n — confirm Fabmed UF before Execute |
| Invalid XML | If optional XSD check is on, fail **before** SOAP with `{:error, {:schema, reasons}}`. If off, send and return SEFAZ `cStat` | Fail-fast vs "let SEFAZ reject" | n — default: XSD **on** in homolog, configurable |
| Lote size | v1 sends **one** NF-e per `NFeAutorizacao4` call (`indSinc` left to caller; default async + `NFeRetAutorizacao4`) | MOC allows up to 50; one is enough for Nexus Oban-per-order | y — simpler MVP |
| Errors | Return `{:ok, result}` for a SOAP envelope that parsed, even if `cStat != 100`. Transport failure is `{:error, reason}` | `204` duplicate is a SEFAZ **business** outcome, not a crash | y |
| Telemetry | `:telemetry` events `[:sefaz_nfe, :soap, :stop]` with UF, service, duration, `cStat` | No PII, no XML body, no cert | y |
| License | Apache-2.0 | Hex-default, Nexus-compatible | n — confirm if org prefers MIT |

**Open questions:** none unmarked — remaining items are assumptions with defaults above.

---

## User Stories

### P1: Sign and authorize one NF-e (modelo 55) ⭐ MVP

**User Story**: As a host app (Nexus), I want to pass a complete NF-e XML and an A1 PFX and get back a protocol or a `cStat` rejection, so that I can stop paying Focus/ACBr per authorization.

**Why P1**: This is the emit path. Without it the lib is DistDFe-only.

**Acceptance Criteria**:

1. WHEN the caller invokes authorize with a well-formed NF-e XML, a PFX, password, `uf`, and `ambiente` (`:homologacao` \| `:producao`) THEN the library SHALL XMLDSig-sign the document (if unsigned), POST it to the UF's **NFeAutorizacao4** (v4.00) with the A1 as TLS client cert, and SHALL NOT insert, remove, or recompute any `imposto` / `total` / `IBSCBS` nodes.
2. WHEN SEFAZ returns `cStat` **103** (lote received) THEN the library SHALL return `{:ok, %{status: :lote_recebido, n_rec: recibo}}` and SHALL NOT invent an authorization protocol.
3. WHEN the caller then consults that recibo via **NFeRetAutorizacao4** and SEFAZ returns `cStat` **100** THEN the library SHALL return `{:ok, %{status: :autorizada, ch_nfe: chave, n_prot: protocolo, xml: proc_nfe_xml}}`.
4. WHEN SEFAZ returns a rejection `cStat` (e.g. schema, duplicate) in a parsed envelope THEN the library SHALL return `{:ok, %{status: :rejeitada, c_stat: integer, x_motivo: binary}}`, not `{:error, ...}`.
5. WHEN the SOAP/TLS layer fails (timeout, NXDOMAIN, HTTP 5xx, SOAP fault) THEN the library SHALL return `{:error, reason}` and SHALL NOT claim a `cStat`.
6. WHEN `ambiente` is `:producao` and the XML `tpAmb` is `2` (or the reverse) THEN the library SHALL refuse with `{:error, :ambiente_mismatch}` before sending.

**Independent Test**: Fixture XML (unsigned, homolog `tpAmb=2`) + test A1 against the UF homolog URL; assert a parsed `cStat` and that the sent body still contains the original `vICMS`/`vProd` bytes (or equivalent checksum of tax nodes).

---

### P1: Consult status of the authorization service ⭐ MVP

**User Story**: As an operator, I want `NFeStatusServico4` before a lote so that a down SEFAZ is visible as `cStat` 107/108/109, not as a hang.

**Why P1**: Cheap, official, and the first SOAP call to prove mTLS + endpoint table.

**Acceptance Criteria**:

1. WHEN `status_servico/1` is called with `uf` + `ambiente` + A1 THEN the library SHALL call **NFeStatusServico4** for that UF and return `{:ok, %{c_stat: integer, x_motivo: binary, t_med: integer | nil}}`.
2. WHEN the UF has no 4.00 URL in the endpoint table THEN the library SHALL return `{:error, {:unknown_endpoint, uf, :nfe_status_servico}}` without a network call.

**Independent Test**: Homolog call for the Fabmed UF; assert `c_stat` is an integer (107 = em operação, per MOC).

---

### P1: DistDFe by NSU ⭐ MVP

**User Story**: As Fabmed, I want documents issued **against** my CNPJ without Focus counting each received XML as a billable note, so that inbound volume stops dominating COGS.

**Why P1**: Received notes are what blows the Growth 4 000 pack. DistDFe is the AN service built for this.

**Acceptance Criteria**:

1. WHEN `dist_dfe/1` is called with CNPJ (or CPF), A1, `ambiente`, and `ult_nsu` THEN the library SHALL call **NFeDistribuicaoDFe** v1.00 on the Ambiente Nacional (`www1.nfe.fazenda.gov.br` in produção; homolog URL from the same official table) and return `{:ok, %{ult_nsu: binary, max_nsu: binary, documents: [doc]}}`.
2. WHEN a document in the response is gzip+base64 (standard DistDFe compression) THEN the library SHALL decode it to XML in `doc.xml` and SHALL NOT drop it silently.
3. WHEN SEFAZ returns no new documents THEN `documents` SHALL be `[]` and `ult_nsu` SHALL still be returned so the caller can persist the cursor.
4. WHEN the caller passes `nsu:` or `ch_nfe:` instead of `ult_nsu` THEN the library SHALL use the corresponding DistDFe query type (consulta por NSU / por chave) as defined for that service.
5. WHEN the library is called twice with the same `ult_nsu` THEN it SHALL perform two independent HTTP calls (no hidden cache of NSU). Persistence is the caller's.

**Independent Test**: Homolog DistDFe with the Fabmed A1 and `ult_nsu = 0`; assert a map with `ult_nsu`/`max_nsu` keys even if `documents` is empty.

---

### P1: Consult protocol by access key ⭐ MVP

**User Story**: As a host app retrying after a crash between 103 and 100, I want **NFeConsultaProtocolo4** by 44-digit key so I do not resend a lote blindly.

**Why P1**: Idempotency of emit without storing only the recibo.

**Acceptance Criteria**:

1. WHEN `consulta_protocolo/1` is given a 44-digit `ch_nfe`, UF, ambiente, A1 THEN the library SHALL call **NFeConsultaProtocolo4** and return the parsed `cStat` / `nProt` / `xMotivo`.
2. WHEN `ch_nfe` is not 44 digits THEN the library SHALL return `{:error, :invalid_ch_nfe}` without SOAP.

**Independent Test**: After a homolog authorization, consult the returned chave; assert `c_stat == 100` (or the homolog equivalent recorded in the fixture).

---

### P2: Cancelamento and CCe (RecepcaoEvento4)

**User Story**: As an operator, I want event 110111 (cancel) and 110110 (CCe) so that post-authorization lifecycle is not still on Focus.

**Why P2**: Emit + DistDFe already kill the quota; events are fewer.

**Acceptance Criteria**:

1. WHEN `cancela/1` is called with chave, protocol, justification (≥15 chars per MOC), A1 THEN the library SHALL sign the event and POST **NFeRecepcaoEvento4** on the authorizing UF.
2. WHEN justification is shorter than the MOC minimum THEN the library SHALL return `{:error, :justificativa_curta}` before SOAP.
3. WHEN `cce/1` is called with chave, correction text, and sequence THEN the library SHALL send event 110110 the same way.

**Independent Test**: Homolog cancel of a previously authorized test NF-e; assert event `cStat` in the parsed envelope.

---

### P2: Optional XSD validation before send

**User Story**: As a developer, I want official XSD check on the ERP XML so a missing IBS group fails locally instead of as a SEFAZ rejection after mTLS.

**Why P2**: Schemas change (PL_010, CNPJ alfa). Shipping last week's XSD as mandatory would block reforma tests.

**Acceptance Criteria**:

1. WHEN validation is enabled and the XML fails the packaged schema THEN authorize SHALL NOT call SOAP.
2. WHEN validation is disabled THEN authorize SHALL send regardless.
3. WHEN a new schema zip is published on the official portal THEN updating the library SHALL be a data bump (schema files + hash), not an API break.

**Independent Test**: Truncated `<NFe>` fixture with validation on → `{:error, {:schema, _}}`; same fixture with validation off → network attempted (stubbed).

---

### P3: Inutilização de numeração

**User Story**: As an ERP, I want **NFeInutilizacao4** so broken number ranges are closed.

**Why P3**: Rare path; not Fabmed COGS.

**Acceptance Criteria**:

1. WHEN `inutiliza/1` is called with serie, nNF range, year, justification, A1, UF THEN the library SHALL call **NFeInutilizacao4** and return the parsed `cStat`.

---

## Edge Cases

- WHEN the PFX password is wrong THEN the library SHALL return `{:error, :invalid_certificate}` before SOAP and SHALL NOT log the password.
- WHEN SOAP times out after the lote may have been accepted THEN the library SHALL return `{:error, :timeout}` and SHALL NOT retry internally (caller uses `consulta_protocolo` / `ret_autorizacao`).
- WHEN two processes authorize the same `nNF` THEN SEFAZ decides (`cStat` duplicate); the library SHALL not mutex globally.
- WHEN DistDFe returns `cStat` meaning "too many requests" / consumo indevido THEN the library SHALL surface that `cStat` in `{:ok, _}` so the caller can back off (Oban).
- WHEN XML is already signed THEN authorize SHALL NOT double-sign.
- WHEN `uf` is `AN` for authorization THEN the library SHALL reject: authorization is not AN; DistDFe is.

---

## Implicit-requirement dimensions

| Dimension | Resolution |
| --- | --- |
| Input validation & bounds | `ch_nfe` 44 digits; `ambiente` atom; PFX parse; CCe/cancel justification length |
| Failure / partial-failure | Timeout ≠ `cStat`; no auto-retry of Autorizacao |
| Idempotency / retry | Caller retries consult, not silent re-lote |
| Auth boundaries | A1 only; no API keys |
| Concurrency | Stateless; concurrent calls with different certs are allowed |
| Data lifecycle | No stored XML/cert; caller deletes |
| Observability | Telemetry without payload/cert |
| External-dependency failure | `{:error, _}` ; no hidden SVC switch (AD-005) |
| State-transition integrity | Library does not own NF-e state machine; it reports SEFAZ `cStat` |

---

## Requirement Traceability

| Requirement ID | Story | Phase | Status |
| --- | --- | --- | --- |
| SEFAZ-01 | P1: Sign and authorize | Design | Pending |
| SEFAZ-02 | P1: RetAutorizacao / cStat 100 | Design | Pending |
| SEFAZ-03 | P1: Rejection as `{:ok, :rejeitada}` | Design | Pending |
| SEFAZ-04 | P1: No tax node mutation | Design | Pending |
| SEFAZ-05 | P1: StatusServico4 | Design | Pending |
| SEFAZ-06 | P1: DistDFe ultNSU | Design | Pending |
| SEFAZ-07 | P1: DistDFe gzip documents | Design | Pending |
| SEFAZ-08 | P1: ConsultaProtocolo4 | Design | Pending |
| SEFAZ-09 | P1: ambiente_mismatch | Design | Pending |
| SEFAZ-10 | P2: Cancel 110111 | - | Pending |
| SEFAZ-11 | P2: CCe 110110 | - | Pending |
| SEFAZ-12 | P2: Optional XSD | - | Pending |
| SEFAZ-13 | P3: Inutilizacao4 | - | Pending |
| SEFAZ-14 | Observability telemetry | Design | Pending |
| SEFAZ-15 | Cert password never logged | Design | Pending |

**Coverage:** 15 total, 0 mapped to tasks (Tasks phase not run).

---

## Success Criteria

- [ ] One homologação NF-e authorized (`cStat` 100) with Fabmed (or a test) A1, XML supplied by caller, tax groups byte-identical to input
- [ ] DistDFe returns a cursor (`ult_nsu` / `max_nsu`) against AN homolog or produção
- [ ] `mix test` suite never hits the network (SOAP client is a behaviour)
- [ ] Wiki lists official RFB URLs as source of truth for endpoints/schemas
