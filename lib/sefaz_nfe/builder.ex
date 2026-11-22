defmodule SefazNfe.Builder do
  @moduledoc """
  Builds the unsigned `NFe` XML from a map that mirrors the layout (AD-021,
  AD-024, AD-025). It walks `SefazNfe.Layout.nfe/0`, so element order, optional
  and required parts, choices and the facets of every value come from the
  official PL, not from code. It never computes or fills a value: the only two
  it writes itself are `infNFe/@versao` (`4.00`) and `det/@nItem` (the item's
  position).

  The result is `<NFe xmlns="http://www.portalfiscal.inf.br/nfe"><infNFe ...>`
  with no `infNFeSupl` (`SefazNfe.NFCe.put_supl/2`) and no `Signature`
  (`SefazNfe.Signer`).

  ## Input

  The map is the content of `infNFe`:

      %{
        id: "NFe35260...",              # attribute Id; optional, see "Access key"
        ide: %{c_uf: 35, ..., ver_proc: "erp"},
        emit: %{cnpj: "...", ...},
        det: [%{prod: %{...}, imposto: %{icms: %{icms00: %{...}}}}],
        total: %{icms_tot: %{...}},
        transp: %{mod_frete: 9},
        pag: %{det_pag: [%{t_pag: "01", v_pag: "100.00"}]}
      }

    * **Keys** are the layout keys (`SefazNfe.Layout.Generator`: `vICMSUFDest`
      is `:v_icms_uf_dest`). Atom or string keys are accepted, never both for the
      same key (`:duplicate_key`). Strings are matched against the layout's own
      keys; the input never creates an atom. A key the layout does not know at
      that point is `:unknown_key`.
    * **Order** is the layout's, never the input's. An optional key that is absent
      (or `nil`) is omitted; a required one is `:required`.
    * **Lists**: an element with `maxOccurs > 1` (`det`, `det_pag`, `dup`,
      `rastro`, `aut_xml`, ...) takes a list, checked against `minOccurs` and
      `maxOccurs` (`{:occurs, min, max, got}`). A single map there is
      `:not_a_list`.
    * **Choices** are selected by key. `imposto.icms` takes exactly one of
      `icms00`, `icms10`, ... . Some choices have *sequences* as branches with
      no element around them (`ipi_trib`: `v_bc`+`p_ipi` or `q_unid`+`v_unid`;
      `imposto`: `icms`/`ipi`/`ii` or `ipi`/`issqn`). The branch is the one
      whose keys contain every key the caller gave for the choice; none is
      `:choice_none`, keys that no single branch holds are
      `{:choice_many, keys}`, and keys several branches hold (only `ipi` alone
      under `imposto`) are `{:choice_ambiguous, keys}`. A sequence that is
      optional as a whole (`dh_cont` + `x_just`) is taken as present when any of
      its keys is given, and then its required members are required.
    * **Leaves**: binaries are validated as they are (pattern, every inherited
      pattern, enumeration, lengths in characters) and only XML-escaped.
      Integers are stringified. For a decimal type (`TDec*`), an integer or a
      `Decimal` (optional dependency) is written with the least places the type
      allows (`TDec_1302` is 2, `TDec_0302a04` is 2 to 4), never fewer digits
      than the value has: a value that needs more places than the type allows is
      `{:precision, max_places}`, not rounded. Floats are `:float_not_allowed`,
      anything else `:invalid_type`.
    * **Attributes** are emitted in name order (the canonical order, so `Id`
      before `versao`). `det/@nItem` is the 1-based position; a given `n_item`
      must equal it (`{:invalid_n_item, position}`).

  ## Access key

  `id` is optional. Without it the key is generated from `ide` (`c_uf`,
  `dh_emi`, `mod`, `serie`, `n_nf`, `tp_emis`, and `c_nf` when given) and `emit`
  (`cnpj` or `cpf`) by `SefazNfe.AccessKey`; `ide.c_nf` is generated when absent
  and `ide.c_dv` is computed, both written into the document, and
  `id = "NFe" <> key`. A `c_dv` or `id` the caller gave that disagrees with the
  key is `{:mismatch, expected}`, and a `c_nf` equal to `n_nf` is
  `:equals_n_nf` (`cStat` 897). Inputs the key needs that are missing or invalid
  are reported as usual, once.

  ## Errors

  Every problem in the tree is collected, not just the first:

      {:error, [{[:det, 0, :prod, :x_prod], :required},
                {[:total, :icms_tot, :v_nf], {:pattern, "..."}}]}

  Paths are keys and list indexes from the `infNFe` content, sorted.

  ## CT-e, CT-e OS and MDF-e

  `build_cte/2`, `build_cte_os/2` and `build_mdfe/2` are this same walk over
  `SefazNfe.Layout.cte/0`, `cte_os/0` and `mdfe/0` (AD-026); the rules above
  (keys, lists, choices, leaves, errors) apply unchanged. What differs:

    * The input is the content of `infCte` / `infMDFe`; the root is `CTe`
      (`http://www.portalfiscal.inf.br/cte`), `CTeOS` (same namespace, with its
      own `versao="4.00"`) or `MDFe` (`http://www.portalfiscal.inf.br/mdfe`).
      `infCte/@versao` is `4.00`, `infMDFe/@versao` `3.00`.
    * The key is the same 44 digits (`SefazNfe.AccessKey`), from `ide` and
      `emit` (`cnpj` or `cpf`). The number is `n_ct` / `n_mdf`, the random code
      `c_ct` / `c_mdf`, written with `c_dv` and `id` (`"CTe" <> key` for CT-e
      and CT-e OS, `"MDFe" <> key`).
    * **Modal**. `inf_modal` is `%{versao_modal: "4.00", rodo: %{...}}` (CT-e),
      `%{versao_modal: "4.00", rodo_os: %{...}}` (CT-e OS) or
      `%{versao_modal: "3.00", rodo: %{...}}` (MDF-e). The modal key picks its
      layout (`SefazNfe.Layout.modal/1`), which is walked like the rest and
      written inside `infModal`, in the document's own namespace. Only the road
      modals are supported: another modal of the family (`aereo`, `aquav`,
      `ferrov`, `duto`, `multimodal`, or the road modal of the other document)
      is `{[:inf_modal, key], {:unsupported_modal, key}}`; none is
      `{[:inf_modal], :choice_none}` and two are `{:choice_many, keys}`. Errors
      inside it have paths like `[:inf_modal, :rodo, :rntrc]`.

  ## Options

    * `:declaration` - prepend `<?xml version="1.0" encoding="UTF-8"?>`
      (default `false`; the SOAP envelope and `SefazNfe.Result` strip it anyway).
  """

  alias SefazNfe.Builder.Document
  alias SefazNfe.Builder.Key
  alias SefazNfe.Builder.Parser
  alias SefazNfe.Builder.Walker
  alias SefazNfe.Layout

  @declaration ~s(<?xml version="1.0" encoding="UTF-8"?>)

  @type path :: [atom() | String.t() | non_neg_integer()]
  @type reason :: term()
  @type error :: {path(), reason()}

  @doc """
  Builds the unsigned NF-e / NFC-e XML from `input`, the content of `infNFe`.

  Returns `{:ok, %{xml: xml, access_key: key}}`. The key is the one in `Id`,
  see "Access key" in the module doc.
  """
  @spec build_nfe(map(), keyword()) ::
          {:ok, %{xml: String.t(), access_key: String.t()}} | {:error, [error()]}
  def build_nfe(input, opts \\ []), do: build(:nfe, input, opts)

  @doc """
  Builds the unsigned CT-e (model 57) XML from `input`, the content of `infCte`
  (`SefazNfe.Layout.cte/0`).

  Same rules as `build_nfe/2`, see "CT-e, CT-e OS and MDF-e". Returns
  `{:ok, %{xml: xml, access_key: key}}`; `Id` is `"CTe" <> key`, `ide.c_ct` and
  `ide.c_dv` are generated when absent, `infCte/@versao` is `4.00`.
  """
  @spec build_cte(map(), keyword()) ::
          {:ok, %{xml: String.t(), access_key: String.t()}} | {:error, [error()]}
  def build_cte(input, opts \\ []), do: build(:cte, input, opts)

  @doc """
  Builds the unsigned CT-e OS (model 67) XML from `input`, the content of
  `infCte` (`SefazNfe.Layout.cte_os/0`). The root `CTeOS` carries `versao="4.00"`
  as well, and the modal key is `rodo_os`.
  """
  @spec build_cte_os(map(), keyword()) ::
          {:ok, %{xml: String.t(), access_key: String.t()}} | {:error, [error()]}
  def build_cte_os(input, opts \\ []), do: build(:cte_os, input, opts)

  @doc """
  Builds the unsigned MDF-e (model 58) XML from `input`, the content of `infMDFe`
  (`SefazNfe.Layout.mdfe/0`). `Id` is `"MDFe" <> key`, `ide.c_mdf` and
  `ide.c_dv` are generated when absent, `infMDFe/@versao` is `3.00`.
  """
  @spec build_mdfe(map(), keyword()) ::
          {:ok, %{xml: String.t(), access_key: String.t()}} | {:error, [error()]}
  def build_mdfe(input, opts \\ []), do: build(:mdfe, input, opts)

  defp build(kind, input, opts) when is_map(input) and not is_struct(input) do
    document = Document.get(kind)
    inf = Layout.find(document.layout, [document.inf])
    absent = Key.absent(input, document)
    {input, key_errors, key} = Key.prepare(input, document)

    case Walker.run(document, inf, input) do
      {body, []} when key_errors == [] ->
        xml = [
          if(Keyword.get(opts, :declaration, false), do: @declaration, else: []),
          "<",
          document.root,
          ~s( xmlns="),
          document.layout.namespace,
          ~s("),
          root_versao(document),
          ">",
          body,
          "</",
          document.root,
          ">"
        ]

        {:ok, %{xml: IO.iodata_to_binary(xml), access_key: key}}

      {_body, errors} ->
        all = key_errors ++ errors
        {:error, all |> drop_ungenerated(key, absent) |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp build(_kind, _input, _opts), do: {:error, [{[], :invalid_type}]}

  defp root_versao(%{root_versao: nil}), do: []
  defp root_versao(%{root_versao: versao}), do: [~s( versao="), versao, ~s(")]

  @doc """
  Reads an `NFe` or an `nfeProc` back into the map `build_nfe/2` takes
  (NFePHP's `Standardize`).

  Returns `{:ok, parsed}` with one shape for both documents:

      %{
        nfe: map,              # the content of infNFe, the builder's input
        supl: map | nil,       # infNFeSupl (NFC-e QR code), when present
        protocol: map | nil,   # protNFe, only in an nfeProc
        signed?: boolean       # a Signature element is present
      }

  The signature itself is not returned: it is the signed bytes that matter
  (`SefazNfe.Signer`), never a re-read of them.

  `nfe` is walked with the same layout tree as the builder, so keys are the
  same snake_case keys, elements with `maxOccurs > 1` are always lists (also
  with one occurrence), choices are the selected branch's key
  (`icms: %{icms00: %{...}}`) and an empty element is `true`. Attributes are
  keys too: `id`, `versao` (`infNFe/@versao`) and `n_item` (`det/@nItem`) are
  included, as strings, so that `build_nfe(parsed.nfe)` writes the document
  again, and `parse_nfe(xml).nfe` is exactly the input once its leaves are
  strings (the generated `c_nf`, `c_dv` and `id` included).

  `protocol` is `protNFe` as a flat map of strings: `:versao`, `:id`, and the
  `infProt` fields `:tp_amb`, `:ver_aplic`, `:ch_nfe`, `:dh_recbto`, `:n_prot`,
  `:dig_val`, `:c_stat`, `:x_motivo` (and `:c_msg`, `:x_msg` when present).

  Leaves are the exact XML text (entities resolved, nothing trimmed or
  converted), so the result is lossless. Reading is by element name inside
  the NF-e namespace, whatever the prefix. An element the layout does not know
  (a newer PL) is `{:error, {:unknown_element, path}}`, an attribute
  `{:error, {:unknown_attribute, path}}`; a second occurrence of an element
  with `maxOccurs` 1 is `{:error, {:duplicate_element, path}}`. A DTD, a
  malformed document or a root that is neither `NFe` nor `nfeProc`
  (`{:unexpected_root, name}`) is an error too.

  ## Options

    * `:strict` - `false` keeps what the layout does not know under
      `:__unknown__` of the element that holds it (tag, or `"@name"` for an
      attribute, to raw text; an element with children is a map of its own).
      Such a map is no longer builder input. Default `true`.
    * `:decimals` - `true` turns the `TDec*` leaves into `Decimal` and integer
      leaves into integers (`{:error, :decimal_not_loaded}` when the optional
      `Decimal` is not available). NF-e leaves other than `TDec*` are text
      types in the XSD and stay strings. Default `false`.
  """
  @spec parse_nfe(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def parse_nfe(xml, opts \\ []) when is_binary(xml), do: Parser.parse(:nfe, xml, opts)

  @doc """
  Reads a `CTe` or a `cteProc` back into the map `build_cte/2` takes.

  Same as `parse_nfe/2` (see "CT-e, CT-e OS and MDF-e" for what changes): the
  result is `%{cte: map, supl: map | nil, protocol: map | nil, signed?: boolean}`,
  with `supl` the `infCTeSupl` and `protocol` the `protCTe` (its `chCTe` is
  `:ch_cte`).
  """
  @spec parse_cte(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def parse_cte(xml, opts \\ []) when is_binary(xml), do: Parser.parse(:cte, xml, opts)

  @doc """
  Reads a `CTeOS` or a `cteOSProc` back into the map `build_cte_os/2` takes:
  `%{cte_os: map, supl: ..., protocol: ..., signed?: ...}`.
  """
  @spec parse_cte_os(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def parse_cte_os(xml, opts \\ []) when is_binary(xml), do: Parser.parse(:cte_os, xml, opts)

  @doc """
  Reads an `MDFe` or an `mdfeProc` back into the map `build_mdfe/2` takes:
  `%{mdfe: map, supl: ..., protocol: ..., signed?: ...}`, `protocol` being the
  `protMDFe` (its `chMDFe` is `:ch_mdfe`).
  """
  @spec parse_mdfe(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def parse_mdfe(xml, opts \\ []) when is_binary(xml), do: Parser.parse(:mdfe, xml, opts)

  # Without a key nothing can be generated, and the field that stopped it is
  # already an error of its own; a bare `:required` for what would have been
  # generated (`id`, `cNF`, `cDV`) would only repeat it.
  defp drop_ungenerated(errors, nil, absent) do
    others = Enum.reject(errors, fn {path, reason} -> reason == :required and path in absent end)
    if others == [], do: errors, else: others
  end

  defp drop_ungenerated(errors, _key, _absent), do: errors
end
