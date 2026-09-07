# Changelog

## 0.1.0-alpha.1

First release. SEFAZ NF-e transport for modelo 55: sign, send, consult,
distribute. It does not calculate taxes — the ERP builds the XML and this
library talks to SEFAZ.

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

### Not yet proven

No `cStat` 100. Reaching it needs an emitter CNPJ credenciado in a UF's
homologation with its real IE and address, which is registration data rather
than code. Until then the authorized-document path — parsing a real `protNFe`
and consulting a real receipt — is covered by fixtures only.

### Verified against production SEFAZ

**DistDFe works**, in homologation and production. The Ambiente Nacional
answers `cStat` 137 for an empty page and returns a real cursor — for the
certificate used in testing, production reported `ultNSU` 2728. This is the
service that decides inbound cost, and it is reachable from every state
because it lives on the AN.

`service_status/1` returns `cStat` 107 from **SP, MG, BA, GO, MT, MS and MA**.

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

**OTP already fixed this on `maint` (OTP-20327)**, and it will ship in the next
minor. That release does not exist yet: as of 2026-09-07 the newest is OTP
29.0.6, and no released runtime carries the fix — not 29.0.x, not 28, not 27.
`maint` and `maint-29` both report `SSL_VSN = 11.7.5`, so the version string
does not distinguish a patched runtime; test a connection instead. A backport
is requested in [erlang/otp#11595](https://github.com/erlang/otp/issues/11595).

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
