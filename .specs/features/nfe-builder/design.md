# nfe-builder Design

**Roadmap**: Phase 2 (`.specs/ROADMAP.md`). **Decisions**: AD-021 (builder allowed, no tax
arithmetic), AD-024 (layout generated from the PL), AD-025 (input shape).
**Consumer**: a Phoenix API with the same HTTP contract as `fiscal-gateway`, so a
client migrates by changing the domain. The builder stays generic; that API maps
the gateway's JSON onto it.

## Goal

`SefazNfe.Builder.build_nfe/1` turns a map that mirrors the NF-e 4.00 layout into
an unsigned `NFe` XML in schema order, with `cNF`, `cDV` and `Id` generated. It
never computes a tax value or a total (AD-001/AD-021): every number comes from
the caller. `SefazNfe.Builder.parse_nfe/1` is the inverse (NFePHP `Standardize`).
`SefazNfe.Proc` exposes the `nfeProc` / `procEventoNFe` / `procInutNFe`
assembly that `authorize/1` already does internally (NFePHP `Complements`).

## Why data-driven

`leiauteNFe_v4.00.xsd` (PL_010_V1.30) is ~7.7k lines with 44 `xs:choice`
groups, and every Nota Técnica moves it. A hand-written `tag*` per group (the
NFePHP `Make` approach) is ~35 functions that must each be re-read against the
XSD on every NT. Instead:

```
PL_010 XSDs ──mix sefaz.gen_layout──▶ priv/layouts/nfe_4.00.etf (committed)
                                          │
input map ──▶ Builder walks the layout ──▶ XML in schema order + errors with paths
XML ───────▶ Builder.parse walks it ─────▶ the same map shape
```

The layout is an ordered tree: element name, input key, min/max occurs,
sequence vs choice, attributes, and for leaves the simple type (pattern,
enumeration, min/max length, decimal places). It is generated from the official
package, never hand-edited, and refreshed per PL like the endpoint table
(AD-004). The XSDs themselves are not vendored (AD-015).

A side effect: the builder validates against the same rules the XSD encodes,
without `:xmerl_xsd`, which cannot compile PL_010.

## Input shape (AD-025)

- Keys are the XSD element names in snake_case (AD-008): `ide.c_uf`,
  `icms_tot.v_bc`, `det[].prod.x_prod`. The layout carries both names, so the
  mapping is exact and reversible. Atom or string keys are accepted.
- `maxOccurs > 1` is a list: `det`, `det_pag`, `dup`, `vol`, `aut_xml`,
  `nf_ref`, `rastro`, …
- A choice is chosen explicitly by its element: `imposto.icms` is
  `%{icms00: %{...}}` or `%{icmssn102: %{...}}`. The builder never infers a
  variant from a CST; that would be a business rule.
- Leaves:
  - strings, validated against the XSD pattern/enumeration/length;
  - integers for integer types;
  - `Decimal` (optional dependency) for decimal types, formatted with the
    type's places **only when no rounding is needed** — `Decimal` "1.005" for a
    2-place field is an error, not "1.01". Floats are refused.
- Attributes: `infNFe/@versao` fixed at 4.00, `infNFe/@Id` generated,
  `det/@nItem` from the list position unless given.
- Errors are collected, not first-fail:
  `{:error, [{[:det, 0, :prod, :x_prod], :required}, {[:total, :icms_tot, :v_nf], {:pattern, "..."}}]}`.

## Access key

From `ide` and `emit`: cUF, `dhEmi` → YYMM, CNPJ/CPF (alphanumeric CNPJ per
NT 2025.001: DV over ASCII − 48), mod, serie, nNF, tpEmis, cNF. `cNF` is
generated when absent (8 random digits, ≠ nNF and not a trivial sequence, per
NT 2019.001 / cStat 897). `cDV` is the mod-11 digit. Both are written back into
`ide`, and `Id = "NFe" <> key`. A caller-supplied `cNF`/`cDV` that disagrees is
an error.

## Out of scope

- Totals, tax values, CFOP or CST selection (AD-001/AD-021).
- Signing (exists: `Signer`) and transmission (exists: `authorize/1`).
- CT-e and MDF-e layouts (Phase 5), though the generator is written to take
  any PL with the same XSD idioms.

## Tasks

| # | Task | Done when |
|---|------|-----------|
| T1 | `mix sefaz.gen_layout PATH` + generated `priv/layouts/nfe_4.00.etf` + `SefazNfe.Layout` loader | Tree covers every `infNFe` element of PL_010_V1.30 incl. choices and types; regeneration is byte-stable; audited by tests |
| T2 | `SefazNfe.Builder.build_nfe/1`: walk, format, validate, escape | Builder output for the test builder's NF-e 55 and NFC-e 65 equivalents validates with xmllint against PL_010; error paths reported |
| T3 | Access key, `cNF`/`cDV`/`Id`; `authorize/1` accepts a map as well as XML | Live: an NF-e and an NFC-e built from maps authorized in BA homologação |
| T4 | `parse_nfe/1` (Standardize) and public `SefazNfe.Proc` | Property: `parse_nfe(build_nfe(m))` returns `m` (normalized) |
| T5 | Gateway golden tests: payloads from `fiscal-gateway` tests rendered by NFePHP vs by the builder | Canonical XML equal for every fixture, or each difference explained |
