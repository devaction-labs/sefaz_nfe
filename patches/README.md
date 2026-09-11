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
DN. It ships in **OTP 29.1**.

On OTP 29 that is the whole answer: 29.1 is the next patch of the line, so
there is nothing earlier to wait for. It is not released yet.

On OTP 28 and 27 there is no imminent minor, so the fix is proposed as a
backport — [erlang/otp#11604](https://github.com/erlang/otp/pull/11604) and
[erlang/otp#11605](https://github.com/erlang/otp/pull/11605).

Do not read `SSL_VSN` to decide whether you need this: `maint` and `maint-29`
both report 11.7.5. Attempt a connection instead.

Until a runtime carrying the fix exists for your line, this patch is the
alternative. Measured against all 27 endpoints
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
