# Spec transport-mvp

Cópia de leitura. **Canônico:** [`.specs/features/transport-mvp/spec.md`](https://github.com/devaction-labs/sefaz_nfe/blob/main/.specs/features/transport-mvp/spec.md) no git.

## Problema

Apps Elixir pagam Focus/ACBr por documento. Não existe no Hex um cliente SEFAZ nativo. DistDFe de distribuidora (Fabmed ~2k pedidos/mês + notas recebidas) estoura o pacote de 4k da Focus.

## P1 (MVP)

1. Assinar e autorizar **uma** NF-e 55 (`NFeAutorizacao4` + `NFeRetAutorizacao4`) **sem alterar nós de imposto**
2. `NFeStatusServico4`
3. DistDFe por `ultNSU` no Ambiente Nacional
4. `NFeConsultaProtocolo4` por chave de 44 dígitos

Rejeição da SEFAZ (`cStat` ≠ 100) é `{:ok, :rejeitada}`, não exceção. Timeout de rede é `{:error, :timeout}` e **não** retenta autorização sozinho.

## P2 / P3

Cancelamento 110111, CCe 110110, XSD opcional, inutilização.

## Fora

Cálculo fiscal, NFC-e, contingência automática, DANFE, produto SaaS.

IDs: `SEFAZ-01` … `SEFAZ-15`.
