defmodule SefazNfe.Layout do
  @moduledoc """
  The NF-e 4.00 layout as data (AD-024), and with it the CT-e, CT-e OS and
  MDF-e ones (AD-026): an ordered tree of elements,
  sequences, choices, attributes and leaf types, generated from the official
  XSD package by `mix sefaz.gen_layout` and committed as
  `priv/layouts/nfe_4.00.etf` (`cte_4.00`, `cte_os_4.00`, `mdfe_3.00` and the
  road modals `cte_modal_rodoviario_4.00`, `cte_os_modal_rodoviario_4.00`,
  `mdfe_modal_rodoviario_3.00` likewise). The builder and its parser walk this tree; it is
  never edited by hand. The refresh procedure is documented in
  `Mix.Tasks.Sefaz.GenLayout`, how each XSD idiom is compiled and how keys are
  derived in `SefazNfe.Layout.Generator`.

  The file is embedded at compile time (`@external_resource`), so a loaded
  `SefazNfe.Layout` carries the tree as a literal: `nfe/0` is a lookup, not a
  parse.

  ## The layout

  `nfe/0` returns a map:

      %{
        generator: 1,                       # generator version
        pl: "PL_010_V1.30",                 # package it was generated from
        namespace: "http://www.portalfiscal.inf.br/nfe",
        root_type: "TNFe",
        sources: [%{file: "leiauteNFe_v4.00.xsd", sha256: "..."}, ...],
        root: element                       # the `NFe` element
      }

  A modal layout (`modal/1`) is generated from one global element whose type
  is anonymous, so it has `root_type: nil` and `root_element: "rodo"`. CT-e and
  CT-e OS share the namespace `http://www.portalfiscal.inf.br/cte`, MDF-e has
  `http://www.portalfiscal.inf.br/mdfe`.

  ## Nodes

  Every node is a plain map with a `:kind`.

  **element** - an XML element:

      %{kind: :element, tag: "vICMSUFDest", key: :v_icms_uf_dest,
        min: 0, max: 1,                     # max is an integer or :unbounded
        type_name: nil | "TEnderEmi",       # named complex type, for messages
        attrs: [attribute],
        content: leaf_type | sequence | choice | nil}

  `content` is a leaf type for a text element, a `sequence` or `choice` for an
  element with children, and `nil` for an empty element. `max > 1` means the
  host passes a list.

  **sequence** and **choice** - `%{kind: :sequence | :choice, min: n,
  max: n | :unbounded, children: [node]}`. Children are elements, foreign
  nodes or further sequences/choices, in XSD order; nesting is kept as
  declared (a choice inside a sequence, a sequence inside a choice).
  `min`/`max` belong to the group itself.

  **foreign** - `%{kind: :foreign, tag: "Signature", key: :signature,
  ns: "http://www.w3.org/2000/09/xmldsig#", min: n, max: n}`: an element of
  another namespace, opaque. The builder never emits it (signing is
  `SefazNfe.Signer`).

  **any** - `%{kind: :any, namespace: "##any", process_contents: :skip,
  min: n, max: n}`: the `xs:any` of `infModal`, where the host places the
  modal XML (itself described by `modal/1`). It has no key and is skipped by
  `elements/1`.

  **attribute** - `%{name: "Id", key: :id, use: :required | :optional,
  type: leaf_type, fixed: binary | nil}`.

  **leaf_type** - the simple type resolved down to its facets:

      %{base: :string,          # :string :id :base64_binary :g_year_month
                                # :decimal :integer :boolean :date ...
        name: "TDec_1302",      # the named type, nil when anonymous
        pattern: binary | nil,  # XSD regex, not translated; the most derived
                                # restriction step
        inherited_patterns: [binary],   # earlier steps; ALL must match too
        enum: [binary] | nil,
        length: n | nil, min_length: n | nil, max_length: n | nil,
        total_digits: n | nil, fraction_digits: n | nil,
        white_space: :preserve | :replace | :collapse | nil,
        min_inclusive: binary | nil, max_inclusive: binary | nil,
        min_exclusive: binary | nil, max_exclusive: binary | nil}

  A leaf of `base: :any_type` is an element declared without any type
  (`xs:anyType`): free text, no facets.

  A leaf is told from a node by having `:base` and no `:kind`.

  The decimal types of the NF-e (`TDec_1302` and friends) are strings
  restricted by a pattern, so their places live in `pattern`, not in
  `fraction_digits`; `name` identifies them.

  ## Keys

  `key` is the snake_case form of the XSD name (`vICMSUFDest` is
  `:v_icms_uf_dest`), unique among the siblings of an element. The algorithm
  and a table of examples are in `SefazNfe.Layout.Generator`.

  ## Paths

  `find/2` walks a list of keys (or XSD tags) from a node or layout, looking
  through `sequence` and `choice`, so `[:inf_nfe, :det, :imposto, :icms]` is
  the `ICMS` element whatever the nesting of choices between them.
  """

  @files %{
    nfe: "nfe_4.00.etf",
    cte: "cte_4.00.etf",
    cte_os: "cte_os_4.00.etf",
    mdfe: "mdfe_3.00.etf",
    cte_rodo: "cte_modal_rodoviario_4.00.etf",
    cte_os_rodo: "cte_os_modal_rodoviario_4.00.etf",
    mdfe_rodo: "mdfe_modal_rodoviario_3.00.etf"
  }

  @layouts Map.new(@files, fn {name, file} ->
             path = Path.expand("../../priv/layouts/" <> file, __DIR__)
             Module.put_attribute(__MODULE__, :external_resource, path)
             {name, path |> File.read!() |> :erlang.binary_to_term()}
           end)

  @type leaf_type :: map()
  @type node_map :: map()
  @type layout :: %{required(:root) => node_map(), optional(atom()) => term()}
  @type modal :: :cte_rodo | :cte_os_rodo | :mdfe_rodo

  @doc "The committed NF-e 4.00 layout."
  @spec nfe() :: layout()
  def nfe, do: @layouts.nfe

  @doc "The committed CT-e 4.00 layout (`TCTe`, model 57), from `PL_CTe_400_RTC`."
  @spec cte() :: layout()
  def cte, do: @layouts.cte

  @doc "The committed CT-e OS 4.00 layout (`TCTeOS`, model 67), from `PL_CTe_400_RTC`."
  @spec cte_os() :: layout()
  def cte_os, do: @layouts.cte_os

  @doc "The committed MDF-e 3.00 layout (`TMDFe`, model 58), from `PL_MDFe_300b`."
  @spec mdfe() :: layout()
  def mdfe, do: @layouts.mdfe

  @doc """
  The layout of a modal, the content of the `infModal` `xs:any` of its
  document: `:cte_rodo` (`rodo` of `cteModalRodoviario`), `:cte_os_rodo`
  (`rodoOS` of `cteModalRodoviarioOS`) and `:mdfe_rodo` (`rodo` of
  `mdfeModalRodoviario`). Only the road modals are generated.
  """
  @spec modal(modal()) :: layout()
  def modal(:cte_rodo), do: @layouts.cte_rodo
  def modal(:cte_os_rodo), do: @layouts.cte_os_rodo
  def modal(:mdfe_rodo), do: @layouts.mdfe_rodo

  @doc """
  The element at `path` below `source` (a layout or a node), or `nil`.

  Path steps are keys (`:det`) or XSD tags (`"det"`).
  """
  @spec find(layout() | node_map(), [atom() | String.t()]) :: node_map() | nil
  def find(%{root: root}, path), do: find(root, path)
  def find(node, []), do: node

  def find(node, [step | rest]) do
    node |> elements() |> Enum.find(&(&1.key == step or &1.tag == step)) |> descend(rest)
  end

  defp descend(nil, _rest), do: nil
  defp descend(node, rest), do: find(node, rest)

  @doc """
  The elements (and foreign nodes) directly inside `node`, in schema order,
  looking through `sequence` and `choice`.
  """
  @spec elements(node_map()) :: [node_map()]
  def elements(%{kind: :element, content: content}), do: flatten(content)
  def elements(%{kind: kind} = group) when kind in [:sequence, :choice], do: flatten(group)

  defp flatten(nil), do: []
  defp flatten(%{base: _leaf}), do: []

  defp flatten(%{kind: kind, children: children}) when kind in [:sequence, :choice],
    do: Enum.flat_map(children, &flatten/1)

  defp flatten(%{kind: kind} = node) when kind in [:element, :foreign], do: [node]
  defp flatten(%{kind: :any}), do: []
end
