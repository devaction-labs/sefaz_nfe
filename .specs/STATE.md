# STATE

## Decisions

### AD-001
- **Decision**: This library performs SEFAZ **transport only** (sign, send, consult, DistDFe, events). It never computes ICMS, PIS, COFINS, IBS, CBS, DIFAL, or invoice totals.
- **Reason**: That arithmetic belongs to the ERP. Focus/ACBr already work this way. Duplicating NFePHP `Make` would make the lib a second tax engine and miss every Nota Técnica of the reforma.
- **Trade-off**: Callers must supply a schema-valid XML (or accept XSD rejection before SOAP).
- **Scope**: entire library
- **Date**: 2026-09-07
- **Amended**: by AD-021 (2026-11-22) — a structural builder is allowed; tax arithmetic is still out.
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

### AD-006
- **Decision**: The DistDFe party identifier is `:tax_id` (CNPJ **or** CPF) across the public API, the `Registry` key and the process label — not `:cnpj`. `SefazNfe.dist_dfe/1` requires it, and `SefazNfe.DistDFe.Poller` requires a `:handler` that receives every page and returns the cursor to continue from.
- **Reason**: DistDFe serves both CNPJ and CPF, so `cnpj` was wrong for half the callers. And the poller previously discarded the result and never advanced `ult_nsu` — a timer with no output. Making `:handler` mandatory turns that silent no-op into a start-time error.
- **Trade-off**: Delivery is at-least-once — the handler runs before the cursor moves, so a raising handler replays the page after the supervisor restart. DistDFe documents are idempotent by NSU, so a replay beats a silent gap. The poller child is `:transient` so a handler answering `:stop` stays down.
- **Scope**: `SefazNfe.dist_dfe/1`, `SefazNfe.DistDFe.Poller`, `SefazNfe.start_dist_dfe_poller/1`
- **Date**: 2026-09-07
- **Status**: active

### AD-007
- **Decision**: PKCS#12 is decoded in-tree by `SefazNfe.Certificate.PKCS12` — a hand-written RFC 7292 reader — rather than by OTP, a Hex dependency or a shell-out to `openssl`.
- **Reason**: OTP 29 ships **no** PKCS#12 support (`:public_key` exports no `pkcs12_to_der`; `:pubkey_pbe` has pbkdf1/pbkdf2 but not the RFC 7292 B.2 KDF, and is an undocumented internal module). Hex has no package for it. Shelling out to `openssl` would put a binary on the runtime path of a Hex library. A1 loading is on the critical path for both mTLS and XMLDSig, so it cannot stay a placeholder.
- **Trade-off**: This is hand-written crypto-adjacent code and warrants review before production. Only `pbeWithSHAAnd3-KeyTripleDES-CBC` with a SHA-1 MAC is supported — verified byte-for-byte against a real ICP-Brasil A1 PJ file and against `openssl` output. PBES2/AES-256 (the OpenSSL 3 export default) is **not** supported and fails as `{:error, {:unsupported_pbe, oid}}` / `{:error, {:unsupported_mac, oid}}`, never as an empty result or a misleading "invalid password".
- **Revised (2026-11-22)**: PBES2 is supported, contrary to the trade-off above: PBES2 with PBKDF2 (HMAC-SHA-1/256/512) and AES-128/192/256-CBC, plus SHA-1 and SHA-256 PKCS#12 MACs, in addition to PBES1 3DES. RC2 and any other algorithm still fail by name. The security review added: bounded work before any KDF/`:crypto` call (PFX <= 64 KiB, <= 32 bags and ContentInfos, iterations in 1..1_000_000, PBKDF2 keyLength = cipher key size; `{:limit_exceeded, _}`); strict PKCS#7 padding; constant-time MAC compare; a catch-all that turns any exception into `{:error, :invalid_certificate}` without keeping the stacktrace; and leaf selection by matching the RSA public key to the private key (`:key_cert_mismatch`, `:multiple_keys`, `{:unsupported_key, _}`) instead of by bag position.
- **Scope**: `SefazNfe.Certificate`, `SefazNfe.Certificate.PKCS12`
- **Date**: 2026-09-07
- **Status**: active

### AD-008
- **Decision**: Everything this project names is in English. Identifiers that mirror SEFAZ artefacts keep the official name: XSD fields (`ch_nfe`↔`chNFe`, `c_stat`↔`cStat`, `x_motivo`, `n_prot`, `n_rec`, `ult_nsu`), service atoms (`:nfe_status_servico`↔`NFeStatusServico4`) and proper nouns (Ambiente Nacional, DistDFe, CCe, UF, NSU).
- **Reason**: A mixed-language API reads as an accident. But renaming SEFAZ's own field names breaks the 1:1 mapping to the MOC and the XSD, which is what makes the library debuggable against the official docs.
- **Trade-off**: `:homologation` / `:production` are English renderings of `tpAmb` 2 / 1. `environment` replaced `ambiente`, `justification` replaced `justificativa`, and the public functions are now `service_status/1`, `consult_protocol/1`, `authorization_result/1`, `cancel/1`, `void_numbers/1`. `ch_nfe` stays: `key` would collide with `Certificate.key`, the private key.
- **Scope**: entire library
- **Date**: 2026-09-07
- **Status**: active

### AD-009
- **Decision**: The library ships **no** TLS trust anchors. Hosts supply ICP-Brasil roots through `config :sefaz_nfe, :cacerts` (a PEM path or DER list), which is added to the system bundle rather than replacing it. `verify_peer` is never relaxed.
- **Reason**: Measured against production: SP and MT serve certificates chained to *Autoridade Certificadora Raiz Brasileira v10*, which is in no OS bundle and is **not** the v5 root embedded in a typical A1 chain. MG and the Ambiente Nacional chain to ordinary commercial roots (Sectigo, GlobalSign) and work out of the box. Without the root, SP fails the handshake.
- **Trade-off**: SP and MT need one configuration line. The alternative — vendoring a CA bundle from a download whose own host cannot be verified (`acraiz.icpbrasil.gov.br` is itself served under ICP-Brasil) — would ship an unaudited trust anchor, which is a man-in-the-middle vector. Operators fetch the roots and check fingerprints themselves. `{:tls, :unknown_ca}` is surfaced by name so the cause is obvious.
- **Note (2026-11-22)**: measured on OTP 29.1.2, 24 of 27 UFs (all but GO, MG and the 403'd MA) need the v10 root, not only SP and MT.
- **Scope**: `SefazNfe.Certificate.ssl_options/1`, `SefazNfe.SOAP.HTTPC`
- **Date**: 2026-09-07
- **Status**: active

### AD-010
- **Decision**: `:httpc` on a private profile is the default SOAP transport, and `:xmerl` the parser. Both are OTP.
- **Reason**: A transport library that drags Finch, Mint, NimblePool and Jason into every host is paying a dependency tax for one HTTP call. `:xmerl` is also the only stdlib option that yields the namespace-aware tree XMLDSig canonicalisation will need.
- **Trade-off**: Erlang-shaped APIs, contained inside `SefazNfe.SOAP.HTTPC` and `SefazNfe.XML`. `:xmerl` has no defence against XXE or entity expansion, so a DTD is refused outright before parsing.
- **Scope**: `SefazNfe.SOAP.HTTPC`, `SefazNfe.XML`
- **Date**: 2026-09-07
- **Status**: active

### AD-011
- **Decision**: Canonical XML 1.0 is implemented in-tree (`SefazNfe.XML.C14N`) and XMLDSig uses RSA-SHA1 with SHA-1 digests, per the MOC 4.00.
- **Reason**: OTP ships no `xmerl_c14n`. SHA-1 is weak everywhere else and is nonetheless what SEFAZ requires; anything stronger is rejected. The signature is spliced into the original bytes rather than produced by re-serialising the parse, because rewriting the ERP's XML would invalidate the signature being added and break SEFAZ-04.
- **Trade-off**: Hand-written canonicalisation, where a one-byte drift yields a well-formed signature that SEFAZ refuses without explaining why. Mitigated by golden tests: every canonical form is compared byte for byte against `xmllint --c14n`, including the apex rule that renders a namespace `infNFe` only inherits. `xmlsec1` could not serve as a whole-signature oracle — the build here fails to load any key, even to sign with an explicit PEM — so verification decomposes into canonical form (xmllint), digest (over that form) and RSA (against the certificate's public key). A homologação `cStat` 100 remains the only end-to-end proof.
- **Scope**: `SefazNfe.XML.C14N`, `SefazNfe.Signer`
- **Date**: 2026-09-07
- **Status**: active

### AD-012
- **Decision**: The per-UF circuit breaker is ETS with atomic counters, not a process per UF. Only transport failures trip it; a SEFAZ `cStat` never does.
- **Reason**: The check runs on every request, and a GenServer per UF would serialise exactly the traffic the breaker protects. Tripping on rejections would take a UF offline for a caller merely sending bad documents.
- **Trade-off**: State transitions are not linearised, so two concurrent callers can both open a breaker or both take the trial call after a cooldown. Harmless here — the worst case is one extra request — and cheaper than a bottleneck.
- **Scope**: `SefazNfe.CircuitBreaker`, `SefazNfe.SOAP.isolated_call/4`
- **Date**: 2026-09-07
- **Status**: active

### AD-013
- **Decision**: `mix sefaz.endpoints` audits the vendored endpoint table and prints the manual refresh procedure. It does not scrape the portal.
- **Reason**: AD-004 requires a documented refresh, and the portal blocks automated fetching. A scraper that silently stored a login page would replace a stale table with a wrong one, which is worse.
- **Trade-off**: Refreshing stays manual. The task fails CI on a snapshot older than 180 days, on a UF whose authorizer or IBGE code is missing, and on any URL that is not an https `.gov.br` address — the failure modes a hand-edited table produces.
- **Scope**: `Mix.Tasks.Sefaz.Endpoints`
- **Date**: 2026-09-07
- **Status**: active

### AD-014
- **Status note (2026-09-07, later the same day)**: superseded by measurement. A `cStat` 100 was obtained against SEFAZ BA homologação once the emitter's real IE was supplied. What follows is the reasoning from before that.
- **Decision**: The emit path is considered verified by SEFAZ's own processing order rather than by a `cStat` 100, which cannot be reached without registering an emitter.
- **Reason**: A homologação round trip against SEFAZ SP with a real ICP-Brasil A1 walked the rejections in order: 225 (schema), 897 (`cNF` equal to `nNF`, NT 2019.001), 1115 (IBS/CBS absent, NT 2025.002), 1026 (IBS rate), and finally **245, CNPJ emitente não cadastrado**. No code in the 280–297 range — certificate and signature errors — was ever returned. SEFAZ validates schema and signature before reaching taxpayer registration, so every layer this library owns is exercised and accepted: PKCS#12, mTLS, SOAP 1.2, XMLDSig with C14N, and response parsing.
- **Trade-off**: The spec's success criterion (`cStat` 100 in homologação) stays unmet, and it is unmeetable here: it needs the certificate holder's CNPJ credenciado as an NF-e emitter in that UF's homologação, with its real IE and address. That is an administrative step on real registration data, not code. The remaining risk this leaves untested is small and specific: the authorized-document path (`protNFe` parsing on a real 100, and `authorization_result/1` against a real receipt).
- **Scope**: `SefazNfe.authorize/1` and the emit path
- **Date**: 2026-09-07
- **Status**: active

### AD-015
- **Decision**: XSD validation is optional and ships no schemas; a host points `config :sefaz_nfe, :schemas` at an unpacked Pacote de Liberação. The compiled schema is **not** cached.
- **Reason**: Schemas change with every Nota Técnica and are megabytes; vendoring them would date the package and bloat it (AD-004). Caching the compiled state looks like an obvious optimisation and is a trap: an `:xmerl_xsd` state references ETS tables that validation releases, so a cached state validates one document and then reports every later one as "element not in schema" — a validator that silently stops validating. The test suite caught exactly that as order-dependent flakiness.
- **Trade-off**: Compilation cost per call, which is milliseconds and only paid when validation is switched on. Local validation names the offending element, where SEFAZ answers `cStat` 225 and names nothing.
- **Scope**: `SefazNfe.Schema`, `SefazNfe.authorize/1`
- **Date**: 2026-09-07
- **Status**: active

### AD-016
- **Decision**: Ship with 20 of 27 UF endpoints unreachable, documented and diagnosed, rather than weakening TLS or delaying. DistDFe, which runs on the Ambiente Nacional, is unaffected and works.
- **Reason**: Root-caused by proxying the handshake and reading OTP's own log. These servers request a client certificate and advertise their acceptable CAs; some of those distinguished names encode `emailAddress` as `PrintableString` rather than `IA5String` — invalid, since `PrintableString` does not admit `@`. `ssl_handshake:decode_cert_auths/2` calls `public_key:pkix_normalize_name/1` on every entry and lets the ASN.1 error (`Type not compatible with table constraint`) abort the handshake. Re-encoding the same DN as `IA5String` decodes cleanly, which confirms the tag is the cause. OpenSSL is lenient and connects.
- **Follow-up (2026-09-08)**: the ssl maintainer confirmed OTP 29.1 is the next patch of the 29 line, so a `maint-29` backport was redundant and that PR was closed — "earlier releases" in her reply meant 28 and 27, which is what the wording already said. The backports that stand are erlang/otp#11604 (`maint-28`) and #11605 (`maint-27`).
- **Trade-off**: OTP had already fixed this on `maint` as OTP-20327, with the same `try/catch` and a test whose fixture is an ICP-Brasil DN; it ships in OTP 29.1. Checking `maint` before opening erlang/otp#11595 would have found it — `SSL_VSN` is 11.7.5 on both `maint` and `maint-29`, so the version string gave no signal, but reading the branch would have. No released OTP carries the fix, so the issue was reframed as a backport request. Upgrading is the answer; `patches/` carries the same change for the interval. No workaround exists inside the library: the handshake transcript is hashed, so a transport shim cannot correct the bytes without breaking `Finished`. `verify_peer` is never relaxed.
- **Resolved (2026-11-22)**: on OTP 29.1.2 the abort is gone and 26 of 27 UFs answer `cStat` 107 with the v10 root (MA fails with a server-side 403 via SVAN). `patches/` was removed. The minimum runtime is OTP 29.1 (AD-020). erlang/otp#11595 is closed and the `maint-28` backport #11604 merged; #11605 (`maint-27`) closed unmerged.
- **Scope**: `SefazNfe.SOAP.HTTPC`
- **Date**: 2026-09-07
- **Status**: active

### AD-017
- **Decision**: The SOAP action is sent as the `action` parameter of the content type, and `NFeDistribuicaoDFe` nests `nfeDadosMsg` inside `nfeDistDFeInteresse` while the UF services keep it flat in the body. `dist_dfe/1` requires `:uf`.
- **Reason**: All three were found against the live Ambiente Nacional, and each produced a different failure that named nothing useful. Without the action it answers "Please supply a valid soap action"; with a flat `nfeDadosMsg` it answers a .NET null reference; with `cUFAutor` set to the AN's own code (91) it answers `cStat` 215, a schema failure. The UF endpoints enforce none of this, so the emit path looked correct while DistDFe was broken.
- **Trade-off**: `:uf` on `dist_dfe/1` and on the poller is a required option rather than a default, because `cUFAutor` is the querying party's own state and the library cannot infer it.
- **Scope**: `SefazNfe.SOAP.Envelope`, `SefazNfe.SOAP.HTTPC`, `SefazNfe.dist_dfe/1`, `SefazNfe.DistDFe.Poller`
- **Date**: 2026-09-07
- **Status**: active

### AD-018
- **Decision**: CT-e (57), MDF-e (58) and the insucesso de entrega event wait for erlang/otp#11595. Manifestação do destinatário was implemented now because it does not depend on it.
- **Reason**: CT-e routes 18 of 27 states through SVRS, which OTP cannot reach — Bahia among them, which is where this is headed. Building it first would deliver something its first user cannot run. Manifestação is processed by the Ambiente Nacional, which works on a stock runtime, and it is the missing half of the DistDFe flow the host app already uses. Insucesso is blocked on reading NT 2021.002 for `hashTentativaEntrega`, and the NF-e portal refuses automated fetch.
- **Trade-off**: The migration from the Focus-based host app stays partial. Research is recorded in `.specs/features/cte/research.md` so the work starts from measurements rather than from a re-run of the same investigation — including that the CT-e portal, unlike the NF-e one, answers automated requests, so its snapshot can come from the official source (AD-004).
- **Note (2026-11-22)**: the blocker, erlang/otp#11595, is resolved (OTP 29.1), so CT-e and MDF-e are unblocked.
- **Scope**: roadmap
- **Date**: 2026-09-07
- **Status**: active

### AD-019
- **Decision**: The lote is synchronous by default (`indSinc` 1). `:sync false` remains for a caller who assembles a real multi-document batch.
- **Reason**: SEFAZ rejects an asynchronous request for a single-document lote outright — `cStat` 452, "Solicitada resposta assincrona para lote com somente 1 (uma) NF-e". This library sends one document per call (AD-003 scope), so the previous asynchronous default guaranteed a rejection on every emission. It was found by running the async path against SEFAZ BA, not by reading.
- **Trade-off**: `authorization_result/1` is no longer the normal continuation. It stays as the recovery path, because SEFAZ may still answer a receipt under load, and because a caller who batches documents will need it.
- **Scope**: `SefazNfe.authorize/1`
- **Date**: 2026-09-07
- **Status**: active

### AD-020
- **Decision**: Require OTP 29.1 or later for the UF services and drop `patches/`.
- **Reason**: The library already targets OTP 29 (AGENTS.md, CI), 29.1 carries OTP-20327, and a patch to OTP source is not something a Hex library should ask hosts to apply.
- **Trade-off**: Hosts on OTP 29.0.x reach only 7 UFs until they upgrade.
- **Scope**: `SefazNfe.SOAP.HTTPC`, docs
- **Date**: 2026-11-22
- **Status**: active

### AD-021
- **Decision**: AD-001 is amended: the library may ship a structural NF-e builder (NFePHP `Make` equivalent) that places caller-supplied values in schema order, generates `cNF`/`cDV`/`Id`, and assembles `nfeProc`/`procEventoNFe`/`procInutNFe`. It still never computes a tax value or a total — the caller passes every number, including totals.
- **Reason**: NFePHP's `Make` already works this way and is what makes it the default choice; requiring hand-built XML is the biggest adoption barrier. The risk AD-001 guards against (becoming a second tax engine that drifts with every NT) is about arithmetic, not structure.
- **Trade-off**: The builder must track schema changes per Pacote de Liberação (layout churn), mitigated by optional XSD validation (AD-015).
- **Scope**: Phase 2 (`SefazNfe.Make` or similar, name TBD)
- **Date**: 2026-11-22
- **Status**: active

### AD-022
- **Decision**: One package (`sefaz_nfe`) until Phase 5 (CT-e/MDF-e). At that point extract `sefaz_core` (certificate/PKCS#12, signer, C14N, SOAP transport, circuit breaker, endpoints machinery) and publish `sefaz_nfe`, `sefaz_cte`, `sefaz_mdfe` on top of it, the way `sped-common` underpins the `sped-*` family.
- **Reason**: Splitting before a second model exists means guessing the seam; CT-e is the first real second consumer.
- **Trade-off**: One later breaking reorganisation of module names for core pieces (plan: keep `SefazNfe.*` aliases/delegates for one minor version).
- **Scope**: packaging
- **Date**: 2026-11-22
- **Status**: active

### AD-023
- **Decision**: The DANFE family (DANFE, DANFE simplificado, DANFCE, DACCE, event/inutilização printouts) is generated in pure Elixir, in a separate package (Phase 4). No headless browser, no wkhtmltopdf, no NIF, no shell-out.
- **Reason**: Same as AD-010 / AD-007 — a Hex library must not put a binary on the host's runtime path.
- **Trade-off**: PDF primitives (text layout, fonts, Code 128C barcode, QR code) must be written or taken from a pure-Elixir dependency, evaluated in Phase 4; layout fidelity to the MOC's DANFE annex is tested by golden PDFs.
- **Scope**: Phase 4 package
- **Date**: 2026-11-22
- **Status**: active

### AD-024
- **Decision**: The NF-e builder is data-driven. `mix sefaz.gen_layout PATH` compiles the official PL package (leiauteNFe + tipos) into an ordered layout tree committed under `priv/layouts/`; the builder and its parser walk that tree.
- **Reason**: PL_010 is ~7.7k lines with 44 choices and moves with every NT. One hand-written function per group (NFePHP `Make`) must be re-read against the XSD each time; a generated layout is refreshed by re-running the task. It also gives XSD-equivalent validation without `:xmerl_xsd`, which cannot compile PL_010.
- **Trade-off**: A small XSD-subset compiler to maintain (sequence, choice, occurs, attributes, simple-type facets). The XSDs stay unvendored (AD-015); only the generated tree ships.
- **Scope**: `SefazNfe.Layout`, `SefazNfe.Builder`, `Mix.Tasks.Sefaz.GenLayout`
- **Date**: 2026-11-22
- **Status**: active

### AD-025
- **Decision**: Builder input mirrors the layout: snake_case XSD names (AD-008), lists for `maxOccurs > 1`, choices selected explicitly by element (`icms: %{icms00: ...}`), strings/integers/`Decimal` leaves formatted without rounding, floats refused, errors collected with paths.
- **Reason**: The builder must be debuggable against the MOC and must not embed business rules; inferring an ICMS variant from a CST, or rounding a value, would be both. The HTTP contract of `fiscal-gateway` is the job of the API built on top, not of the library.
- **Trade-off**: Hosts map their own payload to the layout shape once. `Decimal` becomes an optional dependency.
- **Scope**: `SefazNfe.Builder`
- **Date**: 2026-11-22
- **Status**: active

## Handoff

- **Feature**: Phase 1 of `.specs/ROADMAP.md` (`Tools` parity for NF-e 55 plus NFC-e transport)
- **Phase / Task**: Phase 1 complete, release 0.2.0 prepared (PR `release/0.2.0`). Verified live in homologação on OTP 29.1.2 with a real A1: `service_status/1` 107 on 26/27 UFs (model 55) and 27/27 (model 65); `consult_taxpayer` on the 25 UFs that offer it; NFC-e on BA (authorize 100 with QR 3.00, consult 100, cancel 135); SVC-RS for BA (authorize 100, consult 100, cancel 135).
- **Known gaps**: not verifiable live: SVC-AN, EPEC, DistDFe and manifestação in homologação (AN/SVAN answer HTTP 403 server-side; DistDFe works in production); QR 2.00 (available CSCs rejected as 462, not registered); NFC-e inutilização (SVRS and SP answer 998 Serviço Desativado). `authorization_result/1` still unexercised against a real receipt (AD-019).
- **Next step**: Merge the release PR, tag and publish 0.2.0 (maintainer 2FA), then Phase 2 (builder, AD-021).
- **Blockers**: none
- **Branch**: release/0.2.0
