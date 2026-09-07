# OTP patch: `decode_cert_auths`

Twenty of the twenty-seven SEFAZ state endpoints cannot be reached from
Erlang/OTP. `:ssl` aborts the handshake with `{:tls, :decode_error}` where
OpenSSL, GnuTLS and curl connect to the same hosts without complaint.

The cause is `ssl_handshake:decode_cert_auths/2`. Those servers request a
client certificate and advertise their acceptable CAs; some of those
distinguished names encode `emailAddress` as `PrintableString` instead of
`IA5String`, which is invalid — `PrintableString` does not admit `@` at all.
OTP maps `public_key:pkix_normalize_name/1` over every entry and lets the ASN.1
error abort the connection, even though the field is only a hint for choosing a
client certificate and `ssl_certificate:handle_cert_auths/4` already treats an
empty list as "accept first choice".

## This is already fixed upstream

OTP fixed it on `maint` as **OTP-20327**, merged 2026-08-19, with a
`drop_undecodable_certificate_authorities` test whose fixture is an ICP-Brasil
DN. It will ship in the next OTP minor.

That release does not exist yet. As of 2026-09-07 the newest is OTP 29.0.6, and
no released OTP carries the fix — not 29.0.x, not 28, not 27. `maint` and
`maint-29` both report `SSL_VSN = 11.7.5`, so the version string does not tell
a patched runtime from an unpatched one; test the connection instead. A
backport to the maintenance branches is requested in
[erlang/otp#11595](https://github.com/erlang/otp/issues/11595).

Until that lands there is no released runtime to upgrade to, which is what this
patch is for. Measured against all 27 endpoints
with a real ICP-Brasil certificate: 7 of 27 answered before, 27 of 27 after.

## Checking whether your runtime needs it

```erlang
%% no output means your ssl is patched
{error, _} = ssl:connect("nfe.svrs.rs.gov.br", 443,
                         [{verify, verify_none}, {versions, ['tlsv1.2']}], 15000).
```

## Applying it

This replaces a module inside OTP's `ssl` application, so weigh it as such.

```sh
OTP_SSL=$(erl -noshell -eval 'io:format("~s", [code:lib_dir(ssl)]), halt().')
mkdir -p priv/otp_patch
cp "$OTP_SSL/src/ssl_handshake.erl" priv/otp_patch/
patch -d priv/otp_patch -p4 < patches/otp-decode-cert-auths.patch
erlc -I "$OTP_SSL/src" -I "$OTP_SSL/include" -o priv/otp_patch priv/otp_patch/ssl_handshake.erl
```

Then put `priv/otp_patch` ahead of OTP on the code path — `-pa priv/otp_patch`
in `vm.args`, or `Code.prepend_path/1` before the first TLS connection.

## What you are taking on

`ssl` is security-critical and this pins one of its modules to the source of
one OTP release. The patched module will not receive OTP's security updates,
and it must be rebuilt and re-reviewed on every OTP upgrade — a module compiled
against a different release may not even load.

Treat it as a bridge until the upstream issue is resolved, not as a permanent
arrangement. If that is not acceptable, the ten endpoints that work unpatched
still do, DistDFe on the Ambiente Nacional is unaffected, and
`SefazNfe.SOAP` is a behaviour precisely so a host can substitute its own
transport.
