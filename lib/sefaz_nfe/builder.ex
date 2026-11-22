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

  ## Options

    * `:declaration` - prepend `<?xml version="1.0" encoding="UTF-8"?>`
      (default `false`; the SOAP envelope and `SefazNfe.Result` strip it anyway).
  """

  alias SefazNfe.Builder.Key
  alias SefazNfe.Builder.Leaf
  alias SefazNfe.Builder.Parser
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
  def build_nfe(input, opts \\ [])

  def build_nfe(input, opts) when is_map(input) and not is_struct(input) do
    layout = Layout.nfe()
    inf_nfe = Layout.find(layout, [:inf_nfe])
    absent = Key.absent(input)
    {input, key_errors, key} = Key.prepare(input)

    case emit(inf_nfe, input, [], 1, key_errors) do
      {body, []} ->
        xml = [
          if(Keyword.get(opts, :declaration, false), do: @declaration, else: []),
          ~s(<NFe xmlns="),
          layout.namespace,
          ~s(">),
          body,
          "</NFe>"
        ]

        {:ok, %{xml: IO.iodata_to_binary(xml), access_key: key}}

      {_body, errors} ->
        {:error, errors |> drop_ungenerated(key, absent) |> Enum.uniq() |> Enum.sort()}
    end
  end

  def build_nfe(_input, _opts), do: {:error, [{[], :invalid_type}]}

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
  def parse_nfe(xml, opts \\ []) when is_binary(xml), do: Parser.parse(xml, opts)

  # Without a key nothing can be generated, and the field that stopped it is
  # already an error of its own; a bare `:required` for what would have been
  # generated (`id`, `cNF`, `cDV`) would only repeat it.
  defp drop_ungenerated(errors, nil, absent) do
    others = Enum.reject(errors, fn {path, reason} -> reason == :required and path in absent end)
    if others == [], do: errors, else: others
  end

  defp drop_ungenerated(errors, _key, _absent), do: errors

  # An element ---------------------------------------------------------------
  #
  # `rpath` is the path to the element, reversed. `pos` is its 1-based position
  # in its list (nItem). Every clause returns `{iodata, errors}`.

  defp emit(%{content: %{base: _} = leaf} = element, value, rpath, _pos, errors) do
    case Leaf.text(leaf, value) do
      {:ok, text} -> {[open(element, []), Leaf.escape(text), close(element)], errors}
      {:error, reason} -> {[], [error(rpath, reason) | errors]}
    end
  end

  defp emit(%{content: nil} = element, true, _rpath, _pos, errors),
    do: {["<", element.tag, "/>"], errors}

  defp emit(%{content: content} = element, value, rpath, pos, errors)
       when content != nil and is_map(value) and not is_struct(value) do
    {input, errors} = normalize(value, element, rpath, errors)
    {attributes, errors} = attributes(element, input, rpath, pos, errors)
    {children, errors} = group(content, input, rpath, errors)

    {[open(element, attributes), children, close(element)], errors}
  end

  defp emit(_element, _value, rpath, _pos, errors),
    do: {[], [error(rpath, :invalid_type) | errors]}

  defp open(element, attributes), do: ["<", element.tag, attributes, ">"]
  defp close(element), do: ["</", element.tag, ">"]

  # Keys ---------------------------------------------------------------------

  # Resolves the keys of `value` against the layout's own, so a string key never
  # creates an atom. The result has atom keys only.
  defp normalize(value, element, rpath, errors) do
    known = known_keys(element)

    Enum.reduce(value, {%{}, errors}, fn {given, content}, {acc, errors} ->
      case resolve(given, known) do
        nil ->
          {acc, [error([given | rpath], :unknown_key) | errors]}

        key when is_map_key(acc, key) ->
          {acc, [error([key | rpath], :duplicate_key) | errors]}

        key ->
          {Map.put(acc, key, content), errors}
      end
    end)
  end

  defp resolve(key, known) when is_atom(key), do: if(key in known, do: key)

  defp resolve(key, known) when is_binary(key),
    do: Enum.find(known, &(Atom.to_string(&1) == key))

  defp resolve(_key, _known), do: nil

  defp known_keys(%{attrs: attrs} = element),
    do: keys(element) ++ Enum.map(attrs, & &1.key)

  # The element keys directly inside a node, looking through groups.
  defp keys(node) do
    for %{kind: :element, key: key} <- Layout.elements(node), do: key
  end

  defp present?(input, key), do: Map.get(input, key) != nil

  # Attributes ---------------------------------------------------------------

  defp attributes(%{attrs: attrs} = element, input, rpath, pos, errors) do
    attrs
    |> Enum.sort_by(& &1.name)
    |> Enum.map_reduce(errors, fn attribute, errors ->
      given = Map.get(input, attribute.key)
      attribute(element, attribute, given, [attribute.key | rpath], pos, errors)
    end)
  end

  # versao is fixed; nItem is the position, not something the caller computes.
  defp attribute(%{key: :inf_nfe}, %{key: :versao} = attribute, nil, rpath, _pos, errors),
    do: attribute_text(attribute, "4.00", rpath, errors)

  defp attribute(%{key: :det}, %{key: :n_item} = attribute, given, rpath, pos, errors) do
    expected = Integer.to_string(pos)

    case given do
      nil -> attribute_text(attribute, expected, rpath, errors)
      ^pos -> attribute_text(attribute, expected, rpath, errors)
      ^expected -> attribute_text(attribute, expected, rpath, errors)
      _other -> {[], [error(rpath, {:invalid_n_item, pos}) | errors]}
    end
  end

  defp attribute(_element, %{fixed: fixed} = attribute, nil, rpath, _pos, errors)
       when is_binary(fixed),
       do: attribute_text(attribute, fixed, rpath, errors)

  defp attribute(_element, %{use: :required}, nil, rpath, _pos, errors),
    do: {[], [error(rpath, :required) | errors]}

  defp attribute(_element, _attribute, nil, _rpath, _pos, errors), do: {[], errors}

  defp attribute(_element, attribute, given, rpath, _pos, errors),
    do: attribute_text(attribute, given, rpath, errors)

  defp attribute_text(attribute, value, rpath, errors) do
    case Leaf.text(attribute.type, value) do
      {:ok, text} ->
        {[" ", attribute.name, ~s(="), Leaf.escape(text), ~s(")], errors}

      {:error, reason} ->
        {[], [error(rpath, reason) | errors]}
    end
  end

  # Groups: sequences and choices -------------------------------------------

  # An optional sequence stands in the schema as a group with no element of its
  # own, so it is present when any of its keys is.
  defp group(%{kind: :sequence, min: 0} = sequence, input, rpath, errors) do
    if Enum.any?(keys(sequence), &present?(input, &1)),
      do: members(sequence, input, rpath, errors),
      else: {[], errors}
  end

  defp group(%{kind: :sequence} = sequence, input, rpath, errors),
    do: members(sequence, input, rpath, errors)

  defp group(%{kind: :choice} = choice, input, rpath, errors) do
    given = choice |> keys() |> Enum.uniq() |> Enum.filter(&present?(input, &1))

    case given do
      [] -> choice_none(choice, rpath, errors)
      _ -> choice_branch(choice, given, input, rpath, errors)
    end
  end

  defp members(%{children: children}, input, rpath, errors) do
    Enum.map_reduce(children, errors, fn
      %{kind: :element} = element, errors -> child(element, input, rpath, errors)
      %{kind: :foreign}, errors -> {[], errors}
      group, errors -> group(group, input, rpath, errors)
    end)
  end

  defp choice_none(choice, rpath, errors) do
    if choice.min == 0 or Enum.any?(choice.children, &nullable?/1),
      do: {[], errors},
      else: {[], [error(rpath, :choice_none) | errors]}
  end

  defp choice_branch(choice, given, input, rpath, errors) do
    branches = Enum.filter(choice.children, &(&1.kind != :foreign and given -- keys_of(&1) == []))

    case branches do
      [%{kind: :element} = element] -> child(element, input, rpath, errors)
      [branch] -> group(branch, input, rpath, errors)
      [] -> {[], [error(rpath, {:choice_many, given}) | errors]}
      _several -> {[], [error(rpath, {:choice_ambiguous, given}) | errors]}
    end
  end

  defp keys_of(%{kind: :element, key: key}), do: [key]
  defp keys_of(group), do: keys(group)

  defp nullable?(%{kind: :element, min: min}), do: min == 0
  defp nullable?(%{kind: :sequence, min: 0}), do: true
  defp nullable?(%{kind: :sequence, children: children}), do: Enum.all?(children, &nullable?/1)
  defp nullable?(%{kind: :choice, min: 0}), do: true
  defp nullable?(%{kind: :choice, children: children}), do: Enum.any?(children, &nullable?/1)
  defp nullable?(%{kind: :foreign, min: min}), do: min == 0

  # Occurrence ---------------------------------------------------------------

  defp child(%{key: key, min: min} = element, input, rpath, errors) do
    case Map.get(input, key) do
      nil when min == 0 -> {[], errors}
      nil -> {[], [error([key | rpath], :required) | errors]}
      value -> occurs(element, value, [key | rpath], errors)
    end
  end

  defp occurs(%{max: 1} = element, value, rpath, errors),
    do: emit(element, value, rpath, 1, errors)

  defp occurs(element, items, rpath, errors) when is_list(items) do
    count = length(items)

    errors =
      if count < element.min or (element.max != :unbounded and count > element.max),
        do: [error(rpath, {:occurs, element.min, element.max, count}) | errors],
        else: errors

    items
    |> Enum.with_index()
    |> Enum.map_reduce(errors, fn {item, index}, errors ->
      emit(element, item, [index | rpath], index + 1, errors)
    end)
  end

  defp occurs(_element, _value, rpath, errors), do: {[], [error(rpath, :not_a_list) | errors]}

  defp error(rpath, reason), do: {Enum.reverse(rpath), reason}
end
