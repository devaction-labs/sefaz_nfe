# Fixtures

Throwaway keys, generated for this repository. Never put a real certificate here.

`a1_icp_pj.pfx` and `a1_icp_pf.pfx` (password `sefaz-test`) are self-signed
certificates that carry the ICP-Brasil subjectAltName otherNames, in the PKCS#12
shape the reader supports (3DES + SHA-1 MAC). Generated with OpenSSL 3:

    # pj.cnf: CN=EMPRESA TESTE:99999999999999 (deliberately different from the SAN)
    #   subjectAltName = otherName:2.16.76.1.3.3;UTF8:11222333000181
    # pf.cnf: CN=PESSOA TESTE:00000000000
    #   subjectAltName = otherName:2.16.76.1.3.1;UTF8:0101198012345678909
    openssl req -x509 -newkey rsa:2048 -nodes -keyout k.key -out c.pem -days 3650 -config pj.cnf
    openssl pkcs12 -export -legacy -inkey k.key -in c.pem -out a1_icp_pj.pfx \
      -passout pass:sefaz-test -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

The validity window of both starts on 2026-11-22 and ends on 2036-11-19.

## Hardening fixtures

The sandbox may point `OPENSSL_CONF` at a file that does not exist; `-legacy`
needs a config that activates the `default` and `legacy` providers.

`a1_chain.pfx` (password `sefaz-test`) is a three level chain: a leaf
(`CN=EMPRESA TESTE:00000000000191`) issued by an intermediate, issued by a
self-signed root. The bags hold the leaf, the intermediate and the root; the
tests reorder them to prove the leaf is picked by key, not by position.

    openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key -out root.pem -days 3650 \
      -subj "/CN=TESTE RAIZ" -addext "basicConstraints=critical,CA:TRUE"
    openssl req -newkey rsa:2048 -nodes -keyout int.key -out int.csr -subj "/CN=TESTE INTERMEDIARIA"
    # ext.cnf: [ca] basicConstraints=critical,CA:TRUE / keyUsage=keyCertSign,cRLSign
    openssl x509 -req -in int.csr -CA root.pem -CAkey root.key -CAcreateserial -out int.pem \
      -days 3650 -extfile ext.cnf -extensions ca
    openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj "/CN=EMPRESA TESTE:00000000000191"
    openssl x509 -req -in leaf.csr -CA int.pem -CAkey int.key -CAcreateserial -out leaf.pem -days 3650
    cat int.pem root.pem > ca.pem
    openssl pkcs12 -export -legacy -inkey leaf.key -in leaf.pem -certfile ca.pem -out a1_chain.pfx \
      -passout pass:sefaz-test -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

`a1_unicode.pfx` (3DES, SHA-1 MAC) and `a1_unicode_aes.pfx` (OpenSSL 3 default,
PBES2/AES-256) share one keypair and use the password `sefaz-🔑-çã`, whose key
emoji is outside the BMP: PKCS#12 encodes it as a UTF-16 surrogate pair, PBES2 as
plain UTF-8.

    openssl req -x509 -newkey rsa:2048 -nodes -keyout u.key -out u.pem -days 3650 \
      -subj "/CN=EMPRESA TESTE:00000000000191"
    openssl pkcs12 -export -legacy -inkey u.key -in u.pem -out a1_unicode.pfx \
      -passout 'pass:sefaz-🔑-çã' -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
    openssl pkcs12 -export -inkey u.key -in u.pem -out a1_unicode_aes.pfx -passout 'pass:sefaz-🔑-çã'

The limit, padding, PRF and mismatch cases need no fixture: the tests build DER
by hand (the MAC is bypassed with `PKCS12.decode_safe/2`) or reorder bags through
`PKCS12.collect/1`.
