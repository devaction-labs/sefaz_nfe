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
- **Trade-off**: OTP had already fixed this on `maint` as OTP-20327, with the same `try/catch` and a test whose fixture is an ICP-Brasil DN; it ships in OTP 29.1. Checking `maint` before opening erlang/otp#11595 would have found it — `SSL_VSN` is 11.7.5 on both `maint` and `maint-29`, so the version string gave no signal, but reading the branch would have. No released OTP carries the fix, so the issue was reframed as a backport request. Upgrading is the answer; `patches/` carries the same change for the interval. No workaround exists inside the library: the handshake transcript is hashed, so a transport shim cannot correct the bytes without breaking `Finished`. `verify_peer` is never relaxed.
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

## Handoff

- **Feature**: transport-mvp (`.specs/features/transport-mvp/`)
- **Phase / Task**: **`cStat` 100.** A homologação NF-e was authorized against SEFAZ BA (protocol 129262000191061), and the whole lifecycle followed: CCe and cancellation both `cStat` 135 against that document, inutilização `cStat` 102, DistDFe and manifestação on the Ambiente Nacional. The spec's success criterion, and its gate for a Hex release, is met.
- **Completed**: spec, design, public API in English (AD-008), endpoints snapshot + IBGE cUF, DistDFe poller (AD-006), PKCS#12 reader verified against a real A1 (AD-007), `:httpc` mTLS client and `:xmerl` parser (AD-010), SOAP 1.2 envelopes, `Result.parse/1`, SEFAZ-05 and SEFAZ-14 done, 67 offline tests
- **In-progress**: none
- **Next step**: Publish to Hex (needs the maintainer's 2FA), then CT-e once erlang/otp#11595 lands.
- **Known gaps**: `authorization_result/1` is still unexercised against a real receipt, because a single-document lote is synchronous and never produces one (AD-019); `consult_protocol/1` builds and parses correctly but SEFAZ BA's homologação base does not retain authorized documents, answering `cStat` 217; `SefazNfe.Certificate.PKCS12` is hand-written and wants a security review.
- **Blockers**: none
- **Branch**: main
