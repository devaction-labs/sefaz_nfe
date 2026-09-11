## Summary

A TLS 1.2 client handshake aborts with `decode_error` when the server's
`CertificateRequest` advertises a `certificate_authorities` entry that
`public_key:pkix_normalize_name/1` cannot decode.

`certificate_authorities` is a hint for choosing a client certificate
(RFC 5246 §7.4.4), not a security-relevant field, and `ssl` already handles an
empty list gracefully. One malformed name in that list currently makes the
whole connection fail. OpenSSL, GnuTLS and curl connect to the same servers
without complaint.

This makes several Brazilian tax-authority endpoints (SEFAZ) unreachable from
Erlang/Elixir. They are mandatory for electronic invoicing, so the practical
effect is that no BEAM application can talk to them.

## Reproduction — no network required

One entry from the list advertised by `nfe.svrs.rs.gov.br`. It encodes
`emailAddress` (1.2.840.113549.1.9.1) as `PrintableString` (`0x13`) where
RFC 5280 §4.1.2.6 requires `IA5String` (`0x16`) — and `PrintableString` does
not even admit `@`.

```erlang
DN = <<48,129,176,49,41,48,39,6,9,42,134,72,134,247,13,1,9,1,19,26,
       100,102,116,45,100,102,101,64,112,114,111,99,101,114,103,115,
       46,114,115,46,103,111,118,46,98,114,49,11,48,9,6,3,85,4,8,19,
       2,82,83,49,29,48,27,6,3,85,4,11,19,20,84,101,115,116,101,32,
       80,114,111,106,101,116,111,32,78,70,101,32,82,83,49,29,48,27,
       6,3,85,4,10,19,20,84,101,115,116,101,32,80,114,111,106,101,
       116,111,32,78,70,101,32,82,83,49,21,48,19,6,3,85,4,7,19,12,
       80,79,82,84,79,32,65,76,69,71,82,69,49,11,48,9,6,3,85,4,6,19,
       2,66,82,49,20,48,18,6,3,85,4,3,19,11,65,67,32,82,65,73,90,32,
       68,70,101>>,
public_key:pkix_normalize_name(DN).
%% ** exception error: no match of right hand side value
%%    {error,{asn1,{"Type not compatible with table constraint", ...}}}
```

Changing only the string tag from `0x13` to `0x16` makes the same name decode
cleanly, which isolates the cause to the tag.

## Reproduction — live

```erlang
ssl:connect("nfe.svrs.rs.gov.br", 443, [{verify, verify_none}, {versions, ['tlsv1.2']}], 15000).
%% {error,{tls_alert,{decode_error,"TLS client: In state hello at
%%  tls_handshake.erl:461 generated CLIENT ALERT: Fatal - Decode Error"}}}
```

`openssl s_client -connect nfe.svrs.rs.gov.br:443 -tls1_2` negotiates
`ECDHE-RSA-AES256-GCM-SHA384` against the same host.

With `{log_level, info}` the underlying reason appears:

```
Description: handshake_error
  reason: {badmatch, {ssl_handshake, decode_cert_auths, 2,
                      [{file,"ssl_handshake.erl"},{line,3509}]}}
```

## Root cause

`ssl_handshake:decode_cert_auths/2` (ssl_handshake.erl:3506) maps
`pkix_normalize_name/1` over every advertised name and lets the ASN.1 error
propagate. `tls_handshake:get_tls_handshakes_aux/4` catches it and turns it
into a fatal `decode_error`.

Because the server coalesces ServerHello, Certificate, ServerKeyExchange and
CertificateRequest into a single TLS record, the failure surfaces in state
`hello`, which makes it look like a ServerHello problem. It is not — the
ServerHello is well formed.

## Why this looks like a bug rather than correct strictness

- The field is advisory. RFC 5246 §7.4.4 describes it as a way for the server
  to describe "known roots as well as a desired authorization space".
- `ssl` already degrades gracefully when the list is empty. From
  `ssl_certificate:handle_cert_auths/4`:

  ```erlang
  handle_cert_auths(Chain, [], _, _) ->
      %% If we have no authorities extension (or corresponding
      %% 'certificate_authorities' in the certificate request message in
      %% TLS-1.2 is empty) to check we just accept first choice.
      {ok, Chain};
  ```

  Skipping entries that cannot be parsed therefore degrades into an existing,
  documented path rather than into new behaviour.
- Every other implementation tested (OpenSSL 3.6, GnuTLS, curl) tolerates it.
- Nothing about the malformed hint affects peer verification, which continues
  to run normally.

## Suggested fix

```diff
 decode_cert_auths(<<>>, Acc) ->
     lists:reverse(Acc);
 decode_cert_auths(<<?UINT16(Len), Auth:Len/binary, Rest/binary>>, Acc) ->
-    decode_cert_auths(Rest, [public_key:pkix_normalize_name(Auth) | Acc]).
+    %% certificate_authorities is a hint for picking a client certificate
+    %% (RFC 5246 7.4.4). Entries that cannot be decoded are skipped rather
+    %% than aborting the handshake: an empty list is already handled by
+    %% ssl_certificate:handle_cert_auths/4 as "accept first choice".
+    try public_key:pkix_normalize_name(Auth) of
+        Name ->
+            decode_cert_auths(Rest, [Name | Acc])
+    catch
+        _:_ ->
+            decode_cert_auths(Rest, Acc)
+    end.
```

## Verification

I compiled that change against `ssl-11.7.5` and loaded it ahead of the shipped
module, then queried the `NFeStatusServico4` service of all 27 Brazilian state
endpoints over mTLS with a real ICP-Brasil client certificate:

| | endpoints answering |
|---|---|
| stock OTP 29.0.6 | 7 of 27 |
| with the patch | **27 of 27** |

The twenty that were failing now complete the handshake and return a valid
`cStat` 107. No other behaviour changed, and peer verification stayed on
(`verify_peer`) throughout.

## Environment

- Erlang/OTP 29.0.6, ssl 11.7.5, public_key 1.21.5
- Linux x86_64
- Affected servers include `nfe.svrs.rs.gov.br`, `nfe-homologacao.svrs.rs.gov.br`,
  `nfe.sefa.pr.gov.br`, `nfe.sefazrs.rs.gov.br`, `nfehomolog.sefaz.pe.gov.br`,
  `homnfe.sefaz.am.gov.br` — publicly reachable.

Happy to open a PR with the change and a test case if the approach looks right.
