# Masters checklist (sefaz_nfe)

- [ ] Multi-clause / guards / `with` — no nested `if` for `cStat` or environment
- [ ] `{:ok, %Result{}}` for SEFAZ business; `{:error, _}` for I/O; crash for bugs
- [ ] `@spec` + `@doc` on `SefazNfe` public functions
- [ ] SOAP via `SefazNfe.SOAP.isolated_call/4` (Task.Supervisor)
- [ ] DistDFe poller: Registry + `Process.set_label/1`
- [ ] `Kernel.to_timeout/1` + `Duration` — no magic millisecond literals for waits
- [ ] `JSON` stdlib — no Jason
- [ ] No cert/password in logs or `Inspect`
- [ ] `mix test` offline
- [ ] No `Process.sleep` in tests
