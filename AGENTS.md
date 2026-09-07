# sefaz_nfe

Elixir library: **SEFAZ NF-e transport** (modelo 55). No tax calculation.

## Stack

- Elixir `~> 1.20` / OTP **29**
- Stdlib `JSON`, `Duration`, `Kernel.to_timeout/1`, `Process.set_label/1`
- OTP: `Task.Supervisor`, `Registry`, `DynamicSupervisor`

## Rules

Load `.agents/skills/elixir-masters-patterns/SKILL.md` when writing or reviewing `lib/`.

- Facade is `SefazNfe` only.
- SOAP through `SefazNfe.SOAP.isolated_call/4`.
- DistDFe: one process per CNPJ, labelled, via Registry.
- `mix test` never opens a socket.
- Timeouts: `to_timeout/1`, not raw `30_000`.

Spec: `.specs/features/transport-mvp/spec.md`. Decisions: `.specs/STATE.md`.
