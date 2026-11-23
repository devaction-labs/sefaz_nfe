# Golden against the official RFB calculators

The Receita Federal publishes the calculators of the consumption-tax reform as open
source. This directory uses them as an **oracle** for the IBS, CBS and IS groups
`SefazNfe.Builder` writes. The library computes nothing (AD-001, AD-021): the test feeds
the calculator's numbers into a minimal NF-e and checks that what the builder emits is
what the calculator's own XML generator emits.

| Calculator | Used for |
|---|---|
| [calculadora-rtc-regime-regular](https://github.com/ReceitaFederal/calculadora-rtc-regime-regular) (`POST /regime-geral`, `/xml/generate`, `/xml/validate`) | IBS/CBS/IS values, the NF-e XML groups, and a verdict on OUR fragment |
| [calculadora-rtc-simples-nacional](https://github.com/ReceitaFederal/calculadora-rtc-simples-nacional) (`POST /observabilidade/simples-nacional`) | Simples Nacional results, recorded |

## Layout

* `scenarios/<name>.json`: `{"meta": {...}, "request": {...}}`. `meta.kind` is `calculo`
  (the request goes to `/regime-geral`), `roc` (a hand-written result: the calculator
  does not yet calculate monofásico, crédito presumido, devolução, so its XML generator
  is used as a layout oracle only) or `simples`. `meta.document` is `nfe` or `nfce`.
* `expected/<name>.json`: the calculator's result.
* `expected/<name>.xml`: what `xml/generate` writes for it.
* `expected/<name>.validation.json`: the calculator's `xml/validate` (`subtipo=grupo`)
  verdict on OUR fragment, or why the builder could not build it.
* `expected/RFB_VERSIONS`: commits of both repositories, application and database versions,
  the NT the calculator's XSD follows, and the PL the library targets.

## Re-rendering

```sh
scripts/conformance/rfb_calculator.sh                       # at the pinned commits
RFB_REGIME_REF=latest RFB_SIMPLES_REF=latest scripts/conformance/rfb_calculator.sh
```

It needs podman or docker (never Java on the host), git, curl and network; see the head
of the script. It takes about a minute with a warm cache. `mix test` itself reads the
committed files and never opens a socket.

`.github/workflows/conformance.yml` runs the `latest` variant weekly and on demand, and
fails with the diff when the official output changed. It does not run on pull requests.

## What a failure means

* **The workflow fails with a diff.** RFB changed a rule, a rate table, or the layout of
  the XML it generates. Read the diff: if it is data (a new classification, a rate), re-render
  and commit; if it is a layout (an element renamed, added, reordered), compare with
  the PL the library targets (`SefazNfe.Layout`, `mix sefaz.gen_layout`) and update it, or
  the mapping in `test/support/rfb_calculator.ex`.
* **The golden test fails after a re-render.** Our builder and the calculator no longer
  emit the same group. The failure shows both canonical fragments. If the builder differs
  from the PL, that is a builder bug; if the PL differs from what RFB now generates, the
  PL is behind.
* **A listed difference is gone.** `@differences`, `@not_buildable` and `@refused` in the
  test pin exactly where the calculator (NT v1.36) and PL_010_V1.30 disagree today. When
  one stops being true, remove it.
