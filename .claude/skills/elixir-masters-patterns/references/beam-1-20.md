# Elixir 1.20 / OTP 29 in this repo

Elixir 1.20 requires OTP 27+ and is compatible with OTP 29 (this machine: OTP 29, Mix 1.20.4).

## Stdlib we actually use

| Primitive | Where |
|-----------|--------|
| `JSON.decode!/1` | `SefazNfe.Endpoints` compile-time snapshot |
| `JSON.Encoder` | `SefazNfe.Result` |
| `Duration.new!/1` | DistDFe poller interval |
| `Kernel.to_timeout/1` | SOAP yield + poller `send_after` |
| `Process.set_label/1` / `get_label/1` | DistDFe poller |
| `Task.Supervisor.async_nolink/2` | `SOAP.isolated_call/4` |
| `Registry` unique | `{:dist_dfe, tax_id}` |
| `:telemetry` | SOAP stop events (when SOAP is real) |

## OTP 29 notes

- `ssl` 11.x — TLS 1.3; SEFAZ mTLS still needs the ICP-Brasil chain (AC Raiz). Fail with a TLS reason, do not swallow.
- `public_key` — PFX decode lands here when `Certificate.load/2` stops being a wrapper.
- Process labels show in Observer / `erlang:process_info(Pid, label)`.

## Type inference (1.20)

The compiler infers whole functions. Keep `@spec` matching the clauses you ship. A leftover `defp` that can never match should be deleted, not “just in case”.
