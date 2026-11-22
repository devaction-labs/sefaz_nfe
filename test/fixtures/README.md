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
