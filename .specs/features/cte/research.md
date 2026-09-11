# CT-e (modelo 57) — research

Gathered 2026-09-07. Not started: postponed until the `ssl` limitation
(erlang/otp#11595) is fixed, because most states cannot be reached until then.

## Authorizers, from the official portal

`https://www.cte.fazenda.gov.br/portal/webServices.aspx` — and unlike the NF-e
portal, **this one answers automated requests** (HTTP 200, no redirect). The
CT-e endpoint table can be built from the official source rather than from the
nfephp mirror, which is what AD-004 asks for.

> Estados que utilizam a SVSP - Sefaz Virtual de São Paulo: AP, PE, RR
> Estados que utilizam a SVRS - Sefaz Virtual do RS: AC, AL, AM, BA, CE, DF,
> ES, GO, MA, PA, PB, PI, RJ, RN, RO, SC, SE, TO
> Autorizadores: MT MS MG PR RS SP SVRS SVSP

**The authorizer is per model, not per state.** Bahia issues its own NF-e and
uses SVRS for CT-e; Pernambuco is the reverse, its own NF-e authorizer but SVSP
for CT-e. Reusing `uf_authorizer` from the NF-e snapshot would be wrong.

## Why this is blocked

SVRS serves 18 of the 27 states for CT-e, and SVRS is one of the endpoints OTP
cannot complete a handshake with. Measured with a real ICP-Brasil certificate:

| authorizer | reachable on OTP 29.0.6 |
| --- | --- |
| MG, MS, MT, SP, SVSP, AN | yes |
| PR, RS, **SVRS** | no |

That leaves CT-e usable in 6 states — and not in Bahia, which is where this is
headed. Building it before the runtime is fixed would produce something its
first user cannot run.

## Services (V4)

`CTeRecepcaoSincV4`, `CTeRecepcaoSimpV4` (CT-e Simplificado),
`CTeRecepcaoOSV4` (CT-e Outros Serviços), `CTeRecepcaoGTVeV4` (GTV-e),
`CTeConsultaV4`, `CTeStatusServicoV4`, `CTeRecepcaoEventoV4`, and
`CTeDistribuicaoDFe` on the Ambiente Nacional.

CT-e 4.00 authorizes synchronously, so there is no `RetRecepcao` step as in
NF-e — the protocol comes back in the same call.

## What carries over

The hard parts are done and verified: PKCS#12, mTLS, C14N, XMLDSig, the SOAP
envelope, the circuit breaker, response parsing. CT-e is new message builders
and a new endpoint snapshot on top of that foundation, not a rewrite. The
signature applies to `infCte` exactly as `Signer.sign/4` already handles
`infNFe`, `infEvento` and `infInut`.

## Open questions

- MDF-e (modelo 58) has the same shape and the same SVRS dependency, plus
  stateful flows the Mavorax app uses: encerramento, inclusão de condutor,
  inclusão de DF-e.
- Insucesso de entrega (NF-e event 110192) needs `hashTentativaEntrega`, whose
  algorithm is in NT 2021.002. The NF-e portal blocks automated fetch, so the
  annex has to be read by hand before implementing it. Guessing a hash in a
  fiscal document is how you get a silently wrong event accepted.
