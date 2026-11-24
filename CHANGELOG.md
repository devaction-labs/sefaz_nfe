# Changelog

## 0.4.3

### Added

- `authorization_result/1` and `consult_protocol/1` accept an optional
  `:signed_xml` (the NFe that was sent). With it, and a `protNFe` of the same
  key and digest in the answer, `Result.xml` is the `nfeProc`, as `authorize/1`
  builds it, and `Result.signed_xml` carries it back. A `procEventoNFe` in a
  consultation is not copied into the `nfeProc`. In `consult_protocol/1` a
  `:signed_xml` of another key is `{:error, :signed_xml_key_mismatch}` before
  SEFAZ is called. Without `:signed_xml` nothing changes (AD-027).
- `Result.response_xml`: the SOAP answer exactly as received, envelope included,
  for audit. Set for every operation that returns a `Result`; not in the JSON
  encoding (AD-027).

## 0.4.2

### Verified

- NFC-e QR code 2.00 live in homologação (BA, via SVRS) with a CSC registered
  on 23/11/2026: authorize 100 with the generated `qrCode` (`|2|2|1|<hash>`),
  cancel 135. The earlier 462 came from CSCs that were no longer registered.

### Changed

- Development dependencies refreshed (dialyxir 1.4.9, telemetry 1.4.3 in the
  lock file) and CI actions bumped. No change to the public API or to the
  runtime dependency requirements.

## 0.4.1

### Changed

- The NF-e layout is regenerated from **PL_010h_v1.03**, the newest package on
  the official NF-e portal (published 13/11/2026; NT 2026.005 v1.00,
  NT 2026.006 v1.00, NT 2026.008 v1.01). It only adds to PL_010_V1.30:
  `emit/tpRegimeIBSCBS`, `det/prod/cAtivSN`, and the Simples Nacional IBS/CBS
  group `gTribSN` in `det/imposto/IBSCBS` and `total/IBSCBSTot`. Documents valid
  under V1.30 stay valid. Builder keys `:tp_regime_ibs_cbs`, `:c_ativ_sn` and
  `:g_trib_sn` are new.

### Added

- Conformance against the official Receita Federal calculators
  (`calculadora-rtc-regime-regular` and `calculadora-rtc-simples-nacional`):
  `scripts/conformance/rfb_calculator.sh` runs them in containers (podman or
  docker) and records their results under `test/golden/rfb/`; a golden test
  compares the builder's IBS/CBS/IS groups with them, and a weekly workflow
  re-renders against their latest version. The calculator's XSDs predate the
  official PL (`pISEspec`, flat `gMono*`, `pDevTrib`); those differences are
  asserted, not hidden.

## 0.4.0

### Breaking changes

- The circuit breaker is keyed by the authorizer host (`scheme://host:port` of
  the endpoint actually called), not by UF. `SefazNfe.CircuitBreaker.check/1`,
  `record_success/1` and `record_failure/1` take the host, an open breaker
  returns `{:error, {:circuit_open, host}}` (was the UF), and the SOAP and
  circuit-breaker telemetry events gain a `host` key (`uf` is kept). One UF now
  reaches several servers by model, and many UFs share one (SVRS): a down SVRS
  fails fast for every UF routed there and no longer blocks a UF's NF-e.
- `CStat.classify(132)` is now `:closed` (MDF-e "Encerramento homologado"); it
  was `:rejected` before. `classify/2` (code and model) is new, and
  `classify(134)` is `:authorized`.

Endpoint functions (`Endpoints.url/4`, `contingency_for/2`,
`contingency_url/4`, `operation/3`) gained a trailing `model` argument that
defaults to 55, so NF-e callers are unaffected. `%Result{}` is unchanged.

### Security

- Decimal inputs are bounded: a `Decimal` leaf with `abs(exp) > 40`, more than
  40 coefficient digits, `:inf` or `:NaN` is `{path, :out_of_range}` before any
  `Decimal` call, and `parse_nfe(decimals: true)` only calls `Decimal.parse/1`
  on plain `[0-9]+(.[0-9]+)?` text of at most 40 digits per part. The `decimal`
  requirement is widened to `~> 2.0 or ~> 3.0` so hosts can take the fixes for
  EEF-CVE-2026-32686 (unbounded exponent) and EEF-CVE-2026-97853 (unbounded
  `Decimal.round/3` places; the library does not call it).

### Added

- One package (AD-026, superseding AD-022): CT-e and MDF-e live in
  `SefazNfe.CTe` and `SefazNfe.MDFe` on the same core (certificate, signer,
  C14N, SOAP, breaker, telemetry, layout generator, builder).
- `SefazNfe.CTe` (CT-e 57 and CT-e OS 67): `authorize/1` (synchronous, from a
  map or XML, with the QR code and base64(gzip) transport), `consult/1`,
  `service_status/1`, contingency SVC-SP and SVC-RS (`tpEmis` 8 and 7, explicit
  and validated per UF), `cancel/1`, structured `cce/1`, comprovante de entrega
  and its cancellation (110180/110181) and insucesso de entrega and its
  cancellation (110190/110191). `SefazNfe.CTe.Proc` assembles `cteProc`,
  `cteOSProc`, the event proc and the cancel register.
- `SefazNfe.MDFe` (MDF-e 58): `authorize/1` (with `infMDFeSupl` QR code and the
  contingency signature), `consult/1`, `pending/1` (não encerrados),
  `service_status/1`, `cancel/1`, `close/1` (encerramento), `include_driver/1`
  (inclusão de condutor) and `include_dfe/1` (inclusão de DF-e). `Proc` gains
  the MDF-e procs and registers.
- Endpoint tables for CT-e (`cte_4.00.json`, models 57 and 67) and MDF-e
  (`mdfe_3.00.json`), taken from the official portals; `mix sefaz.endpoints`
  audits all four tables.
- Layouts for CT-e, CT-e OS and MDF-e and their road modals, and
  `Builder.build_cte/2`, `build_cte_os/2`, `build_mdfe/2` with
  `parse_cte/2`, `parse_cte_os/2`, `parse_mdfe/2`. Access keys for models 57,
  67 and 58.
- Layout generator: `xs:any` as a `:any` node, untyped elements as free-text
  leaves, and `--element` for global elements with anonymous types.

### Verified

Live in homologação with a real ICP-Brasil A1:

- `service_status` 107 on 27 of 27 UFs for CT-e 57, CT-e OS 67 and MDF-e 58.
- MDF-e built from a map: authorize 100, consult 100, pending 111/112,
  inclusão de condutor 135, encerramento 135, consult 132.
- CT-e built from a map reached 203 (emitter not credentialed for CT-e):
  schema, signature, QR code and gzip transport were accepted. Consult and
  cancel answered 217 and were parsed; SVC-RS status 107; SVC-SP for BA 114.
  A 100 needs a credentialed emitter.

Golden tests: the builder's canonical `infCte` and `infMDFe` equal
fiscal-gateway's NFePHP output for 10 documents. One NFePHP defect was found:
a vehicle owner with a UF and no IE produces an invalid `prop`; the builder
refuses it.

Tests that depend on the PL XSDs read `SEFAZ_NFE_CTE_PL_PATH` (e.g.
`PL_CTe_400_RTC`) and `SEFAZ_NFE_MDFE_PL_PATH` (e.g. `PL_MDFe_300b`) and skip
without them.

## 0.3.0

### Breaking changes

- `Result.proc/2`, and so the `xml` of `authorize/1`, no longer joins a
  `protNFe` of another access key or a rejection `cStat`: it returns `nil`
  instead of an `nfeProc` that does not belong to the document. It now
  delegates to `SefazNfe.Proc.nfe_proc/2`.

### Changed

- The results of `cancel/1`, `cce/1`, `manifest/2`, `epec/1` and
  `void_numbers/1` now carry `signed_xml` and `xml` (the `procEventoNFe` or
  `procInutNFe` to archive). Additive: existing fields are unchanged.

### Added

- NF-e builder: `SefazNfe.Builder.build_nfe/2` turns a map into the unsigned
  `NFe` XML and returns `{:ok, %{xml: xml, access_key: key}}`. It is
  data-driven from the Pacote de Liberação (`SefazNfe.Layout`, generated by
  `mix sefaz.gen_layout`, AD-024), and the input shape follows AD-025.
  Validation is the XSD's, expressed over the layout (required, choices,
  occurrences, patterns, enumerations, lengths, UTF-8), and every problem is
  collected with its path instead of stopping at the first. `Decimal` is an
  optional dependency, formatted to the field's places and never rounded. No
  value is computed: not totals, not taxes.
- `SefazNfe.AccessKey`: `build/1`, `dv/1`, `random_c_nf/2` (NT 2019.001),
  `valid?/1`, with alphanumeric CNPJ support (NT 2025.001).
- `authorize/1` accepts `nfe:` (the builder's map) instead of `xml:`; a map
  that does not build returns `{:error, {:invalid_nfe, errors}}` before the
  network.
- `Builder.parse_nfe/2`: an `NFe` or `nfeProc` back to the builder's map, with
  the protocol and `infNFeSupl`. The inverse of `build_nfe/2`.
- `SefazNfe.Proc`: `nfe_proc/2`, `event_proc/2`, `void_proc/2` and
  `cancel_register/2` assemble the processed documents as public functions,
  splicing the signed bytes verbatim, with key, digest and `cStat` checks.
- `SefazNfe.Layout`: the NF-e layout as data.

### Verified

Live in SEFAZ-BA homologação, with documents built from maps: NF-e 55
authorize 100 and cancel 135; NFC-e 65 authorize 100 (with the generated QR
3.00) and cancel 135. Real authorized `nfeProc` documents parse, and the
`infNFe` rebuilt from the parsed map is byte-identical to the signed original.

Golden tests: the builder's canonical `infNFe` equals the output of
fiscal-gateway's NFePHP for 11 payloads.

Tests that depend on the PL XSDs read `SEFAZ_NFE_PL_PATH` (the directory of
the Pacote de Liberação, e.g. `PL_010_V1.30`) and skip without it.

## 0.2.0

### Breaking changes

- `Certificate.load/2,3`: a wrong or empty password returns
  `{:error, :invalid_password}` (was `:invalid_certificate`); certificates
  outside their validity window are refused by default
  (`{:expired, not_after}` / `{:not_yet_valid, not_before}`; pass
  `allow_expired: true` to inspect them); new errors `:key_cert_mismatch`,
  `:multiple_keys`, `{:unsupported_key, _}` and `{:limit_exceeded, _}`.
- `Result.status` is classified by `SefazNfe.CStat`: 107 is `:in_operation`
  (was `:rejected`), 110/301/302/303 are `:denied`, 101/151 `:cancelled`, and
  108/109/656/999 `:retryable`. `%Result{}` gains `:dh_recbto`.
- `authorize/1` routes by `<mod>` and `tpEmis`: XML without `<mod>` is refused,
  `tpEmis` 2/3/5 are unsupported, and 4/6/7 require `dhCont` and `xJust`.
- `Certificate.ssl_options/1` presents the PFX chain as the client chain and no
  longer adds it to `:cacerts`.

### Added

- `consult_taxpayer` (`CadConsultaCadastro4`), per UF that offers it.
- NFC-e 65 transport: endpoint routing, QR code 3.00 on-line, and
  `SefazNfe.NFCe.put_supl`.
- QR code 2.00 with CSC, on-line and off-line.
- SVC-AN / SVC-RS routing and the `contingency:` option.
- EPEC (`epec/1`).
- Telemetry: `[:sefaz_nfe, :operation | :soap | :circuit_breaker, ...]`, documented
  in `SefazNfe.Telemetry`.
- Certificate `not_before`, `not_after` and `tax_id`, plus `expired?/2` and
  `days_until_expiry/2`.

### Security

The PKCS#12 reader is hardened (PR #25), since the PFX and its password can be
attacker-controlled in hosts that accept uploads.

- Bounded work: size at most 64 KiB, at most 32 bags, iteration counts capped
  per call and per PFX, PBKDF2 key length checked, all before any key derivation.
- The leaf is the certificate whose RSA public key matches the private key;
  otherwise `:key_cert_mismatch`, `:multiple_keys` or `{:unsupported_key, _}`.
- Parameters are validated before `:crypto`, and a catch-all never keeps a
  stacktrace (crypto errors could carry the derived key or the password).
- Strict PKCS#7 unpadding, unknown PBKDF2 PRFs refused by name, constant-time
  MAC comparison, lossless UTF-16 password encoding, PFX version 3 only, BER
  indefinite length refused.
- The PFX chain is no longer added to `:cacerts`, where it acted as trusted
  roots for the server.

### Fixed

- Event author uses `<CPF>` for CPF emitters.
- The circuit breaker is keyed on the upper-cased UF.

### Verified live (homologação, real ICP-Brasil A1, OTP 29.1.2)

`service_status/1` answers 107 on 26 of 27 UFs for model 55 (MA/SVAN answers
403) and on 27 of 27 for model 65. `consult_taxpayer` was run on the 25 UFs that
offer it: BA answered 111 with the real record, the others 259 (AM and MA do not
offer it). NFC-e on BA (SVRS): authorize 100 with the generated QR 3.00,
consult 100, cancel 135. SVC-RS for BA: authorize 100, consult 100, cancel 135.

Not verifiable live: SVC-AN, EPEC, DistDFe and manifestação in homologação
(AN/SVAN answer HTTP 403 server-side; DistDFe works in production); QR 2.00 (the
available CSCs were rejected as 462, not registered); NFC-e inutilização (SVRS
and SP answer 998 Serviço Desativado).

## 0.1.1

- OTP 29.1 resolves the handshake failure on 20 UFs (OTP-20327). The minimum
  runtime for the per-UF services is now OTP 29.1.
- `patches/` and the upstream issue draft are removed; nothing needs patching.
- Verified live on OTP 29.1.2 against homologação: `service_status/1` answers
  `cStat` 107 on 26 of 27 UFs (MA/SVAN answers 403 server-side). Full SEFAZ BA
  lifecycle: authorize 100, CCe 135, cancel 135, `consult_protocol/1` 100 (it
  can answer 217/494 for a few seconds after authorization), inutilização 102.
  The Ambiente Nacional and SVAN homologação endpoints answer 403 server-side.
- README trust-anchor guidance corrected: the ICP-Brasil v10 root is needed by
  nearly every UF, not only SP and MT; its SHA-256 fingerprint is listed.

`:connect_timeout` never left `SefazNfe.authorize/1` and its siblings, so the
client's 10 second default was the only value there was. Measured against
SEFAZ-BA, `time_connect` ranged from 3.5 seconds to 68.7 across consecutive
requests — connecting is the part of a SEFAZ call that hangs, and a caller had
no way to wait for it. It is forwarded now, and the task window is the longer of
the two deadlines rather than the request one.

`isolated_call/4` consumed `:timeout` for the task supervising the request and
never forwarded it to the client, which kept its own 30 second default. The
option could therefore shorten a call and never lengthen one — a caller raising
it to two minutes still got `{:error, :timeout}` at thirty seconds, from a
deadline it had no way to reach. It now reaches the client, and the task waits a
five second grace beyond it so a request timeout is reported by the client that
knows it was one.

`Signer` spliced the `Signature` at a grapheme offset where the match had been
measured in bytes. One accented character before the closing tag — `Móveis`,
`Açaí`, any real emitter name — moved the cut one position early, producing
`</infNFe><<Signature ...</Signature>/NFe>`: a document that is no longer
well-formed.

SEFAZ answers that with a bare `HTTP 400 Bad Request` and an empty body, so the
failure names nothing and reads like a transport or certificate problem. It is
neither. Every document the library signed for a Brazilian issuer was affected
unless the whole note happened to be ASCII.

The signer test fixture was ASCII, which is why 174 passing tests said nothing
about it. It carries an accent now, and a second test signs the same document
under Latin-1 and CJK names to keep the byte count honest.

## 0.1.0

SEFAZ NF-e transport for modelo 55: sign, send, consult, distribute. It does
not calculate taxes — the ERP builds the XML and this library talks to SEFAZ.

### Since 0.1.0-alpha.1

The alpha shipped without a single authorized document; that is what the
designation meant. An NF-e has since been authorized in homologação, along with
the events around it, so this release drops it.

Three defects surfaced while doing that, none of which a unit test would have
caught:

- The lote defaulted to asynchronous, and SEFAZ rejects an asynchronous request
  for a single-document batch (`cStat` 452). Since this library sends one
  document per call, the default guaranteed a rejection on every emission. It
  is synchronous now.
- `cStat` 102 — how SEFAZ reports a voided number range — was mapped as a
  rejection, so `void_numbers/1` reported failure on success.
- `authorize/1` discarded the signed document and never filled `Result.xml`,
  losing the `nfeProc` that has to be archived and delivered. A protocol number
  alone proves nothing without the bytes it refers to.

Also new: `manifest/2` for manifestação do destinatário, which is the other
half of the DistDFe flow — confirming an operation is what releases the full
XML of a note that arrived as a summary.

### What works

- **A1 certificates.** OTP 29 ships no PKCS#12 support and Hex has no package
  for it, so `SefazNfe.Certificate.PKCS12` reads the PFX itself per RFC 7292.
  Verified byte for byte against `openssl` on a real ICP-Brasil A1. Supports
  `PBE-SHA1-3DES` (what ICP-Brasil issues) and PBES2 with AES. A wrong password
  fails on the MAC before any network call.
- **mTLS transport** over `:httpc`, on a private profile so the library never
  touches the host's global HTTP settings. Zero new dependencies.
- **XMLDSig** with Canonical XML 1.0, written here because OTP has no
  `xmerl_c14n`. Every canonical form in the test suite is compared byte for
  byte against `xmllint --c14n`, including the apex rule that renders a
  namespace `infNFe` only inherits.
- **Nine services**: `authorize/1`, `authorization_result/1`,
  `service_status/1`, `dist_dfe/1`, `consult_protocol/1`, `cancel/1`, `cce/1`,
  `void_numbers/1` and `manifest/2`, plus a DistDFe poller per tax ID.
- **Manifestação do destinatário** — `:confirmation`, `:awareness`, `:unaware`
  and `:not_performed`. These pair with DistDFe: confirming an operation is
  what releases the full XML of a note you only received a summary of.
- **The authorized document comes back.** `authorize/1` returns `:signed_xml`
  (what was sent) and, once a protocol exists, `:xml` holding the `nfeProc` —
  the document that must be archived and delivered. `SefazNfe.Result.proc/2`
  joins the two halves for an asynchronous lote, whose protocol arrives later.
- **Optional XSD validation**, off unless a schema directory is configured.
- **Per-UF circuit breaker**, so a SEFAZ that stops answering cannot stall
  callers working with other states. Only transport failures trip it.
- **Telemetry** on `[:sefaz_nfe, :soap, :start | :stop | :exception]`, carrying
  UF, service and outcome — never the certificate, the password or the body.

### Verified against production SEFAZ

### The full lifecycle, against SEFAZ BA homologation

| step | result |
| --- | --- |
| `authorize/1` | **`cStat` 100, Autorizado o uso da NF-e** — protocol 129262000191061 |
| `nfeProc` | assembled and well formed, signature and totals intact |
| `cce/1` | `cStat` 135, evento registrado e vinculado à NF-e |
| `cancel/1` | `cStat` 135, evento registrado e vinculado à NF-e |
| `void_numbers/1` | `cStat` 102, inutilização homologada |
| `dist_dfe/1` | `cStat` 137 / 656 with a live cursor |
| `manifest/2` | `cStat` 136, evento registrado |
| `service_status/1` | `cStat` 107 |

### Still unproven

`authorization_result/1` has not run against a real receipt: a single-document
lote is synchronous and never produces one. `consult_protocol/1` builds and
parses correctly, but SEFAZ BA's homologation does not retain authorized
documents and answers `cStat` 217.

### Verified against production SEFAZ

**DistDFe works**, in homologation and production. The Ambiente Nacional
answers `cStat` 137 for an empty page and returns a real cursor — for the
certificate used in testing, production reported `ultNSU` 2728. This is the
service that decides inbound cost, and it is reachable from every state
because it lives on the AN.

`service_status/1` returns `cStat` 107 from **SP, MG, BA, GO, MT, MS and MA**.

**An NF-e was authorized.** `cStat` 100 against SEFAZ BA homologation, protocol
129262000191061, with the `nfeProc` assembled and archivable.

**Manifestação do destinatário is registered by SEFAZ.** A `:awareness` and a
`:not_performed` event sent to the Ambiente Nacional in homologation both came
back `cStat` **136, Evento registrado** — signature validated and the event
recorded. This is the first document this library gets SEFAZ to actually
store, rather than answer a query about.

`authorize/1` reaches SEFAZ SP's taxpayer-registration check and stops at
`cStat` **245, CNPJ emitente não cadastrado** — schema and signature accepted,
nothing in the 280–297 range where certificate and signature failures live.

### A known OTP limitation: 20 of 27 UF endpoints

The per-UF services cannot connect to SVRS, PR, RS, PE or AM — 20 states in
total. `:ssl` aborts with `{:tls, :decode_error}` where `openssl s_client
-tls1_2` connects to the same host without complaint.

The cause is precise and is not configuration. These servers request a client
certificate and list their acceptable CAs; some of those distinguished names
encode `emailAddress` as `PrintableString` instead of `IA5String`, which is
invalid — `PrintableString` does not even admit `@`. OTP's
`ssl_handshake:decode_cert_auths/2` calls `public_key:pkix_normalize_name/1` on
every entry and lets the ASN.1 error abort the handshake, so one malformed name
in an advisory list kills the connection. OpenSSL is lenient and connects.

The field is only a hint for choosing a client certificate, and
`ssl_certificate:handle_cert_auths/4` already treats an empty list as "accept
first choice", so skipping undecodable entries degrades into an existing path.

**OTP fixed this on `maint` as OTP-20327, and it ships in OTP 29.1.** On OTP 29,
upgrading to 29.1 is the answer — the maintainer confirmed it is the next patch
of that line, so there is no 29.0.7 to wait for. As of 2026-09-08 it is not out
yet, and no released runtime carries the fix.

For OTP 28 and 27 there is no imminent minor, so the fix is proposed as a
backport: [erlang/otp#11604](https://github.com/erlang/otp/pull/11604) and
[erlang/otp#11605](https://github.com/erlang/otp/pull/11605).

Do not check the version to tell whether your runtime is affected: `maint` and
`maint-29` both report `SSL_VSN = 11.7.5`. Attempt a connection instead.

Until that release exists there is nothing to upgrade to. `patches/` carries
the same change for the interval and is explicit about what pinning a module
inside `ssl` costs. With it, all 27 endpoints answer `cStat` 107 instead of 7
of 27.

When a blocked endpoint is reached, the error is
`{:tls, :decode_error, :otp_cert_auths_bug}` rather than a bare alert, so it
names the runtime limitation instead of looking like a certificate problem.

### What works on a stock OTP

| | |
|---|---|
| DistDFe on the Ambiente Nacional | works, homologation and production |
| SVC-AN contingency | works |
| Per-UF services in BA, GO, MA, MG, MS, MT, SP | work |
| Per-UF services in the other 20 states | blocked |
| SVC-RS contingency | blocked |

There is no workaround inside the library itself: the handshake transcript is
hashed, so the bytes cannot be corrected in flight. DistDFe is unaffected.

### Known limits

- Contingency (SVC-AN, SVC-RS, EPEC, FS-DA) is not automatic. A down SEFAZ
  returns an error and the caller chooses; silent failover can duplicate an
  authorization.
- No trust anchors ship with the package. SP and MT serve certificates chained
  to *Autoridade Certificadora Raiz Brasileira*, which no OS bundle carries;
  supply it with `config :sefaz_nfe, :cacerts`. Vendoring a CA bundle from a
  download whose own host cannot be verified would be a man-in-the-middle
  vector.
- `SefazNfe.Certificate.PKCS12` and `SefazNfe.XML.C14N` are hand-written
  crypto-adjacent code. They are tested against reference implementations, and
  they deserve a security review before carrying production emission traffic.
- NFC-e (65), CT-e, MDF-e, NFS-e and DANFE are out of scope.
