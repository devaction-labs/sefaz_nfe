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

## Handoff

- **Feature**: transport-mvp (`.specs/features/transport-mvp/`)
- **Phase / Task**: mTLS transport live. `service_status/1` verified end to end against SEFAZ SP, MT and MG (`cStat` 107) with a real ICP-Brasil A1. XMLDSig still unwritten.
- **Completed**: spec, design, public API in English (AD-008), endpoints snapshot + IBGE cUF, DistDFe poller (AD-006), PKCS#12 reader verified against a real A1 (AD-007), `:httpc` mTLS client and `:xmerl` parser (AD-010), SOAP 1.2 envelopes, `Result.parse/1`, SEFAZ-05 and SEFAZ-14 done, 67 offline tests
- **In-progress**: none
- **Next step**: `enviNFe` message builder plus `retEnviNFe` parsing, then a real `cStat` 100 in homologação — the gate the spec sets before any Hex publish. That needs a schema-valid NF-e from an ERP, which this library does not build (AD-001).
- **Known gaps**: `authorize/1` signs but has no `enviNFe` builder yet, so it posts the bare document; `cancel/1`, `cce/1` and `void_numbers/1` need their event and inutilização message builders (the Signer already handles their `infEvento` / `infInut` via `Signer.sign/4`); `dist_dfe/1`, `consult_protocol/1`, `authorization_result/1` and `void_numbers/1` still need their message builders and response parsers (`retDistDFeInt` also needs gzip+base64, SEFAZ-07); no circuit breaker per UF yet — required before this carries emission traffic; PBES2/AES-256 PFX files are rejected rather than read (AD-007); the AD-004 refresh procedure for the endpoint snapshot is still not written; `SefazNfe.Certificate.PKCS12` is hand-written and wants a security review.
- **Blockers**: none
- **Branch**: main
