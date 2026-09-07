# Design

Canônico: [`.specs/features/transport-mvp/design.md`](https://github.com/devaction-labs/sefaz_nfe/blob/main/.specs/features/transport-mvp/design.md)

```
ERP XML + A1  →  Signer  →  SOAP mTLS  →  SEFAZ UF (4.00)
                              ↘
                                AN DistDFe (1.00)
```

Lib **sem estado**: Nexus/Oban guarda `ultNSU`, `nNF`, recibo.

`mix test` usa behaviour de SOAP — zero rede.

Integração futura no Nexus: mesmo contrato de `NexusPro.Integrations.Acbr.Client` (`submit_nfe`, `get_nfe_status`, `download_xml`).
