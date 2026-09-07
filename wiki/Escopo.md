# Escopo

## Entra no v1

- XMLDSig + mTLS com certificado **A1**
- `NFeAutorizacao4` / `NFeRetAutorizacao4`
- `NFeStatusServico4`
- `NFeConsultaProtocolo4`
- `NFeDistribuicaoDFe` (Ambiente Nacional) — notas **recebidas**
- Lib **stateless** (quem guarda `ultNSU` e `nNF` é o app)

## Não entra

- Cálculo ICMS / IBS / CBS / DIFAL / totais
- Montar XML (`Make` do NFePHP)
- NFC-e, CT-e, MDF-e, NFS-e
- Contingência automática (SVC-AN / SVC-RS)
- DANFE
- Oban, Ecto, produto multi-tenant (isso é o Nexus, depois)

Ver AD-001 … AD-005 em `.specs/STATE.md`.
