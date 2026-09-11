---
name: elixir-masters-patterns
description: >
  Apply Elixir/OTP design principles from José Valim, Saša Jurić, Chris McCord,
  Dave Thomas, and Bruce Tate to sefaz_nfe. Use when designing modules, OTP
  boundaries, SOAP isolation, DistDFe pollers, reviewing PRs, or when the user
  mentions masters, let-it-crash, or BEAM. Also use Elixir 1.20 / OTP 29
  primitives (JSON, Duration, to_timeout, Process.set_label) instead of older
  workarounds.
---

# Elixir Masters Patterns (sefaz_nfe)

This is a **stateless transport library** plus an **optional OTP tree**.
`AGENTS.md` wins on conflict. Tax calculation is never our job (AD-001).

## The five lenses

| Master | One-liner | sefaz_nfe |
|--------|-----------|-----------|
| **Valim** | Data shapes the code | Multi-clause + guards on UF/environment/`cStat`; `with` on the facade; `@spec` on `SefazNfe.*` |
| **Jurić** | Processes and failure domains | SOAP in `Task.Supervisor` (I/O crash ≠ caller crash); DistDFe = one process per `tax_id`; `{:error,_}` for SEFAZ/TLS; crash on programmer bugs |
| **McCord** | One public context | `SefazNfe` is the only entry. Host apps (Nexus) never call `SOAP.client` directly |
| **Thomas** | Orthogonal, small, intentional | Endpoints / Signer / SOAP / Poller do **one** thing; docs explain *why* |
| **Tate** | Patterns on purpose | OTP tree exists because DistDFe *is* a process problem — not because “libraries need a GenServer” |

## Elixir 1.20 + OTP 29 — use these, do not reinvent

Requires OTP 27+; this repo targets **OTP 29** / **Elixir ~> 1.20**.

| Instead of | Use |
|------------|-----|
| Jason / `:json` FFI soup | `JSON.decode!/1` / `JSON.encode!/1` (stdlib) |
| `Process.send_after(pid, msg, 30_000)` magic ints | `Kernel.to_timeout/1` and `Duration` (`to_timeout(second: 30)`, `Duration.new!(minute: 5)`) |
| Unnamed DistDFe workers in observer | `Process.set_label/1` + `Process.get_label/1` |
| Global mutable endpoint map | Compile-time snapshot (`@external_resource` + `JSON`) |
| `try/rescue` around the whole authorize | `Task.Supervisor.async_nolink` + `Task.yield` / `shutdown` |
| Sleep in tests | `assert_receive`, monitors, `Task.yield` |

Type system (1.20 infers whole functions): keep `@spec` honest; dead clauses will be warned — do not leave unused `defp` heads.

## Hard rules

### 1. Control flow (Valim)

Order: **multi-clause → case → with → cond**. `if` only for one-way flags (`pfx == ""`).

SEFAZ `cStat` is data: `100` / `103` / `104` are clauses, not `if c_stat == 100`.

### 2. Errors (Jurić)

| Kind | Shape | Example |
|------|-------|---------|
| SEFAZ business | `{:ok, %Result{status: :rejeitada, c_stat: n}}` | duplicate nNF |
| Expected I/O | `{:error, :timeout \| :invalid_certificate \| {:http, _}}` | TLS, SOAP fault |
| Programmer bug | crash | `authorize("SP")` missing map |

Never `try/rescue` to keep a DistDFe poller “alive” over a logic bug. The supervisor restarts it.

### 3. Facade (McCord, adapted)

- Host calls `SefazNfe.authorize/1`, `dist_dfe/1`, `start_dist_dfe_poller/1`.
- `@doc` + `@spec` on those functions only.
- No Ecto. No Oban in this Hex package (AD-002). Poller is OTP; persistence of `ult_nsu` is the **host**.

### 4. BEAM abuse (this repo’s point)

- **One DistDFe poller per tax ID** — `Registry` unique key `{:dist_dfe, tax_id}` (CNPJ *or* CPF; DistDFe serves both). Thousands of tax IDs = thousands of cheap processes, not a Focus invoice.
- **A poller must deliver** — `:handler` is required and owns the cursor. A poll loop that drops its page is a no-op with a timer.
- **SOAP isolated** — `SefazNfe.SOAP.isolated_call/4` so a NIFless SSL abort does not take down the Nexus request process.
- **Circuit per UF** — when SOAP exists, a down SP must not block MG (PartitionSupervisor / per-UF breaker). Not in the empty shell; do not skip it when implementing SOAP.
- **Labels** — every poller `Process.set_label({:sefaz_nfe, :dist_dfe, tax_id})`.
- **Telemetry** — `[:sefaz_nfe, :soap, :stop]` with UF, service, duration, `c_stat`. Never cert, never XML body, never password.

### 5. Secrets

- `Inspect` for `Certificate` is redacted.
- Logger metadata may include `uf` and `service`, never PFX/password.

## Pre-merge checklist

```
[ ] Multi-clause / with, not nested if for cStat / environment
[ ] Domain/SEFAZ outcomes are {:ok, result}; bugs crash
[ ] SefazNfe. facade is the only public entry
[ ] @spec + @doc on new facade functions
[ ] SOAP goes through Task.Supervisor (isolated_call)
[ ] DistDFe poller labelled; via Registry
[ ] Timeouts are to_timeout/Duration, not raw ms soup
[ ] JSON stdlib, not Jason
[ ] No Process.sleep in tests
[ ] mix test never opens a socket
[ ] mix precommit clean
```

## Anti-patterns

| Anti-pattern | Prefer |
|--------------|--------|
| Porting NFePHP `Make` | ERP builds XML |
| Auto SVC contingency | Return error; host rebuilds `tpEmis` (AD-005) |
| Retry Autorizacao inside the lib | Host consults chave/recibo |
| God GenServer for all UFs | One process per tax ID (DistDFe) / isolated task per SOAP |
| `String.to_atom/1` on UF from XML | Allowlist / `String.upcase/1` binaries |

## Smell scans

```bash
rg -n "Process.sleep" test
rg -n "Jason" lib
rg -n "rescue" lib --type elixir
rg -n "30_000|15_000" lib   # raw timeouts — prefer to_timeout
```
