defmodule SefazNfe.Layout.Generator do
  @moduledoc """
  Compiles the official XSD package (a PL) into the layout tree that
  `SefazNfe.Layout` loads (AD-024). Driven by `mix sefaz.gen_layout`.

  ## Why a subset compiler

  `:xmerl_xsd` cannot compile PL_010, and the builder needs the *shape* of the
  schema, not a validator: element order, occurrence, choices, attributes and
  the facets of every leaf. This module reads exactly the XSD idioms the NF-e
  package uses and **raises** on any other, so a Nota Tecnica that introduces
  a new construct fails generation instead of producing a layout that silently
  drops it.

  ## XSD idioms and how they are handled

    * `xs:include` / `xs:import` are followed (the file name must be a plain
      sibling file). Every file reached is hashed. Definitions are indexed only
      for files in the entry file's target namespace; an imported foreign
      namespace (`ds`) is hashed but not compiled.
    * Global `xs:element` + named `xs:complexType` / `xs:simpleType`, anonymous
      inline `complexType` / `simpleType`, and named types referenced by
      `type=` are all expanded in place. A named complex type is recorded as
      `type_name` on the element; a named simple type as `name` on the leaf.
    * `xs:sequence` and `xs:choice`, nested in any combination
      (choice-in-sequence, sequence-in-choice), keep their own `minOccurs` /
      `maxOccurs` and their children order.
    * `minOccurs` defaults to 1, `maxOccurs` to 1; `"unbounded"` becomes
      `:unbounded`.
    * `xs:attribute` (inline or by `type=`), with `use` and `fixed`.
    * `xs:restriction` chains over `xs:string`, `xs:ID`, `xs:base64Binary`,
      `xs:gYearMonth` and the other built-ins in `@builtins`, resolved down to
      a single flat facet set: `pattern`, `enumeration`, `length`,
      `minLength`, `maxLength`, `totalDigits`, `fractionDigits`, `whiteSpace`,
      `minInclusive`, `maxInclusive`, `minExclusive`, `maxExclusive`.
      Several `xs:pattern` in one restriction are OR-ed into one
      `(a)|(b)` string. A derived type that adds a pattern to a base that
      already has one is an AND: `pattern` holds the most derived step and
      `inherited_patterns` the earlier ones, all of which must match.
    * `xs:element ref=` to a foreign namespace (`ds:Signature`) becomes an
      opaque `%{kind: :foreign, ...}` node.
    * Ignored on purpose (they constrain documents, not the shape the builder
      walks): `xs:annotation` and the identity constraints `xs:unique`,
      `xs:key`, `xs:keyref`. The only ones in PL_010 are uniqueness checks on
      `gPgto/@nPag`, `gPgto/@idTransacao` and `@dia`.
    * Not supported, raised: `xs:any`, `xs:group`, `xs:attributeGroup`,
      `xs:extension`, `xs:simpleContent`, `xs:complexContent`, `xs:list`,
      `xs:union`, `mixed`, and recursive types.

  ## Keys

  `snake_case/1` turns an XSD name into the key hosts write in their input
  map. The algorithm:

    1. `NFe` is treated as one acronym (`NFE`).
    2. The name is cut into runs of capitals, of lowercase letters and of
       digits; digits stay attached to the run before them.
    3. A run of capitals followed by lowercase gives its last capital to the
       next word (`ICMSUFDest` is `ICMSUF` + `Dest`). That head is then split
       on known acronyms (`@acronyms`) when it is made only of them; a run at
       the end of the name is never split.
    4. Words are lowercased and joined with `_`.

  | XSD name        | key               |
  |-----------------|-------------------|
  | `vICMSUFDest`   | `v_icms_uf_dest`  |
  | `CNPJ`          | `cnpj`            |
  | `ICMS00`        | `icms00`          |
  | `ICMSSN102`     | `icmssn102`       |
  | `infNFeSupl`    | `inf_nfe_supl`    |
  | `xPed`          | `x_ped`           |
  | `nItemPed`      | `n_item_ped`      |
  | `IBSCBS`        | `ibscbs`          |
  | `gIBSCBS`       | `g_ibscbs`        |
  | `vIBSUF`        | `v_ibsuf`         |
  | `vBCSTDest`     | `v_bc_st_dest`    |
  | `ISSQNtot`      | `issqn_tot`       |
  | `CNPJBasePSP`   | `cnpj_base_psp`   |

  Two sibling elements/attributes of the same element (looking through
  `sequence` and `choice`) whose *different* XSD names map to one key abort
  generation. Keys are atoms created at generation time from a trusted local XSD, never
  from network data; the layout stores them as atoms.
  """

  require Record

  alias SefazNfe.XML

  Record.defrecordp(
    :xml_element,
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xml_attribute,
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xml_namespace,
    :xmlNamespace,
    Record.extract(:xmlNamespace, from_lib: "xmerl/include/xmerl.hrl")
  )

  @xsd_ns "http://www.w3.org/2001/XMLSchema"
  @version 1
  @default_entry "nfe_v4.00.xsd"
  @default_root "TNFe"

  @builtins %{
    "string" => :string,
    "normalizedString" => :string,
    "token" => :string,
    "ID" => :id,
    "base64Binary" => :base64_binary,
    "gYearMonth" => :g_year_month,
    "decimal" => :decimal,
    "integer" => :integer,
    "int" => :integer,
    "long" => :integer,
    "short" => :integer,
    "byte" => :integer,
    "nonNegativeInteger" => :integer,
    "positiveInteger" => :integer,
    "unsignedInt" => :integer,
    "unsignedLong" => :integer,
    "boolean" => :boolean,
    "date" => :date,
    "dateTime" => :date_time,
    "time" => :time
  }

  @acronyms ~w(ISSQN COFINS NFE ICMS CNPJ CFOP CEST CSLL CIDE IRRF FCP IBS CBS IPI PIS CST CPF EAN NCM CRT MVA IOF ANP GLP BC ST UF IS SN NF IE)
            |> Enum.sort_by(&{-String.length(&1), &1})

  @facet_ints %{
    "length" => :length,
    "minLength" => :min_length,
    "maxLength" => :max_length,
    "totalDigits" => :total_digits,
    "fractionDigits" => :fraction_digits
  }

  @facet_strings %{
    "minInclusive" => :min_inclusive,
    "maxInclusive" => :max_inclusive,
    "minExclusive" => :min_exclusive,
    "maxExclusive" => :max_exclusive
  }

  @doc "The generator version recorded in every layout."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  Compiles the package in `dir`.

  Options: `:entry` (the XSD that includes the rest, default
  `#{@default_entry}`) and `:root` (the complex type to compile, default
  `#{@default_root}`). Raises on any unsupported idiom.
  """
  @spec generate(Path.t(), keyword()) :: map()
  def generate(dir, opts \\ []) do
    entry = Keyword.get(opts, :entry, @default_entry)
    root_type = Keyword.get(opts, :root, @default_root)

    files = load(dir, [entry], %{})
    target_ns = files |> Map.fetch!(entry) |> then(& &1.tree.attrs["targetNamespace"])
    ctx = files |> adopt(target_ns) |> index(target_ns)

    %{
      generator: @version,
      pl: dir |> Path.expand() |> Path.basename(),
      namespace: target_ns,
      root_type: root_type,
      sources:
        files
        |> Enum.sort()
        |> Enum.map(fn {file, %{sha256: sha}} -> %{file: file, sha256: sha} end),
      root: ctx |> root_element(root_type) |> element(ctx, [])
    }
  end

  @doc "Serializes a layout deterministically, so regeneration is byte-stable."
  @spec encode(map()) :: binary()
  def encode(layout), do: :erlang.term_to_binary(layout, [:deterministic, compressed: 9])

  # ---- loading ----------------------------------------------------------

  defp load(_dir, [], acc), do: acc

  defp load(dir, [file | rest], acc) when is_map_key(acc, file), do: load(dir, rest, acc)

  defp load(dir, [file | rest], acc) do
    plain_file!(file)
    body = dir |> Path.join(file) |> File.read!()

    tree =
      case XML.parse(body) do
        {:ok, doc} -> to_tree(doc)
        {:error, reason} -> raise ArgumentError, "#{file}: cannot parse XSD (#{inspect(reason)})"
      end

    sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    links = for c <- tree.children, c.tag in ["include", "import"], do: c.attrs["schemaLocation"]

    load(
      dir,
      rest ++ Enum.reject(links, &is_nil/1),
      Map.put(acc, file, %{tree: tree, sha256: sha})
    )
  end

  defp plain_file!(file) do
    if Path.basename(file) != file or file in ["", ".", ".."] do
      raise ArgumentError, "schemaLocation #{inspect(file)} must be a sibling file name"
    end
  end

  defp to_tree(xml_element() = el) do
    {uri, local} = xml_element(el, :expanded_name) |> expanded()

    attrs =
      for a <- xml_element(el, :attributes), into: %{} do
        {Atom.to_string(xml_attribute(a, :name)), chars(xml_attribute(a, :value))}
      end

    children = for c <- xml_element(el, :content), xml_element?(c), do: to_tree(c)

    %{
      tag: local,
      ns: uri,
      attrs: attrs,
      nsmap: nsmap(xml_element(el, :namespace)),
      children: children
    }
  end

  defp xml_element?(term), do: Record.is_record(term, :xmlElement)

  defp expanded({uri, local}), do: {Atom.to_string(uri), Atom.to_string(local)}
  defp expanded(name) when is_atom(name), do: {"", Atom.to_string(name)}

  defp nsmap(xml_namespace(default: default, nodes: nodes)) do
    nodes
    |> Map.new(fn {prefix, uri} -> {List.to_string(prefix), Atom.to_string(uri)} end)
    |> Map.put("", to_string(default))
  end

  defp chars(value) when is_list(value), do: :unicode.characters_to_binary(value)

  # ---- index ------------------------------------------------------------

  # An included file without a targetNamespace (DFeTiposBasicos) is a
  # "chameleon": its unprefixed names live in the namespace of its includer.
  defp adopt(files, target_ns) do
    Map.new(files, fn {file, %{tree: tree} = entry} ->
      case tree.attrs do
        %{"targetNamespace" => _} -> {file, entry}
        _chameleon -> {file, %{entry | tree: adopt_tree(tree, target_ns)}}
      end
    end)
  end

  defp adopt_tree(node, ns) do
    %{
      node
      | nsmap: Map.update(node.nsmap, "", ns, &if(&1 == "", do: ns, else: &1)),
        children: Enum.map(node.children, &adopt_tree(&1, ns)),
        attrs: Map.put_new(node.attrs, "targetNamespace", ns)
    }
  end

  defp index(files, target_ns) do
    for {file, %{tree: %{attrs: %{"targetNamespace" => ^target_ns}} = tree}} <- files,
        child <- tree.children,
        child.tag in ["simpleType", "complexType", "element"],
        reduce: %{ns: target_ns, simple: %{}, complex: %{}, elements: %{}} do
      acc ->
        name = Map.fetch!(child.attrs, "name")
        bucket = bucket(child.tag)

        if is_map_key(acc[bucket], name) do
          raise ArgumentError, "#{file}: duplicate definition of #{name}"
        end

        Map.update!(acc, bucket, &Map.put(&1, name, child))
    end
  end

  defp bucket("simpleType"), do: :simple
  defp bucket("complexType"), do: :complex
  defp bucket("element"), do: :elements

  defp root_element(ctx, root_type) do
    case for {_name, e} <- ctx.elements, e.attrs["type"] == root_type, do: e do
      [one] -> one
      [] -> raise ArgumentError, "no global element has type #{root_type}"
      _many -> raise ArgumentError, "several global elements have type #{root_type}"
    end
  end

  # ---- elements ---------------------------------------------------------

  defp occurs(node) do
    %{min: occurs_min(node.attrs["minOccurs"]), max: occurs_max(node.attrs["maxOccurs"])}
  end

  defp occurs_min(nil), do: 1
  defp occurs_min(value), do: String.to_integer(value)
  defp occurs_max(nil), do: 1
  defp occurs_max("unbounded"), do: :unbounded
  defp occurs_max(value), do: String.to_integer(value)

  # `stack` is the named types being expanded (cycle guard), `path` the tags
  # walked so far (error messages). They travel together as one `trail`.
  defp element(node, ctx, trail), do: element(node, ctx, trail, [])

  defp element(%{attrs: %{"ref" => ref}} = node, ctx, trail, path) do
    {uri, local} = qname(ref, node)
    occurs = occurs(node)

    if uri == ctx.ns do
      ctx.elements |> Map.fetch!(local) |> element(ctx, trail, path) |> Map.merge(occurs)
    else
      Map.merge(%{kind: :foreign, tag: local, key: key(local), ns: uri}, occurs)
    end
  end

  defp element(%{attrs: %{"name" => tag}} = node, ctx, trail, path) do
    path = path ++ [tag]
    {type_name, content, attrs} = element_type(node, ctx, trail, path)

    element =
      Map.merge(
        %{
          kind: :element,
          tag: tag,
          key: key(tag),
          type_name: type_name,
          attrs: attrs,
          content: content
        },
        occurs(node)
      )

    check_keys!(element, path)
    element
  end

  defp element_type(%{attrs: %{"type" => type}} = node, ctx, trail, path) do
    {uri, local} = qname(type, node)

    cond do
      uri == @xsd_ns ->
        {nil, builtin_leaf(local, "xs:" <> local), []}

      uri == ctx.ns and is_map_key(ctx.simple, local) ->
        {nil, simple(ctx.simple[local], local, ctx, trail), []}

      uri == ctx.ns and is_map_key(ctx.complex, local) ->
        {content, attrs} = complex(ctx.complex[local], local, ctx, trail, path)
        {local, content, attrs}

      true ->
        raise ArgumentError, "#{Enum.join(path, "/")}: unknown type #{type}"
    end
  end

  defp element_type(node, ctx, trail, path) do
    case for c <- node.children, c.tag in ["simpleType", "complexType"], do: c do
      [%{tag: "simpleType"} = t] ->
        {nil, simple(t, nil, ctx, trail), []}

      [%{tag: "complexType"} = t] ->
        {content, attrs} = complex(t, nil, ctx, trail, path)
        {nil, content, attrs}

      _none_or_many ->
        raise ArgumentError, "#{Enum.join(path, "/")}: element without a usable type"
    end
  end

  defp complex(%{attrs: attrs} = node, name, ctx, trail, path) do
    if attrs["mixed"] == "true",
      do: raise(ArgumentError, "mixed content at #{Enum.join(path, "/")}")

    if name in trail do
      raise ArgumentError, "recursive type #{name} at #{Enum.join(path, "/")}"
    end

    trail = if name, do: [name | trail], else: trail
    parts = for c <- node.children, c.tag != "annotation", do: c
    {attributes, particles} = Enum.split_with(parts, &(&1.tag == "attribute"))

    content =
      case particles do
        [] ->
          nil

        [%{tag: tag} = p] when tag in ["sequence", "choice"] ->
          particle(p, ctx, trail, path)

        [other | _] ->
          raise ArgumentError, "unsupported <#{other.tag}> at #{Enum.join(path, "/")}"
      end

    {content, Enum.map(attributes, &attribute(&1, ctx, trail, path))}
  end

  defp particle(%{tag: tag} = node, ctx, trail, path) do
    children =
      for child <- node.children, child.tag != "annotation" do
        case child.tag do
          "element" -> element(child, ctx, trail, path)
          t when t in ["sequence", "choice"] -> particle(child, ctx, trail, path)
          t -> raise ArgumentError, "unsupported <#{t}> at #{Enum.join(path, "/")}"
        end
      end

    Map.merge(%{kind: String.to_existing_atom(tag), children: children}, occurs(node))
  end

  # ---- attributes -------------------------------------------------------

  defp attribute(%{attrs: %{"name" => name} = attrs} = node, ctx, trail, path) do
    type =
      case attrs do
        %{"type" => type} ->
          {uri, local} = qname(type, node)
          attribute_type(uri, local, ctx, trail, path)

        _inline ->
          [t] = for c <- node.children, c.tag == "simpleType", do: c
          simple(t, nil, ctx, trail)
      end

    %{name: name, key: key(name), use: usage(attrs["use"]), type: type, fixed: attrs["fixed"]}
  end

  defp attribute_type(@xsd_ns, local, _ctx, _trail, _path),
    do: builtin_leaf(local, "xs:" <> local)

  defp attribute_type(ns, local, %{ns: ns} = ctx, trail, path) do
    case ctx.simple do
      %{^local => node} -> simple(node, local, ctx, trail)
      _ -> raise ArgumentError, "#{Enum.join(path, "/")}: unknown attribute type #{local}"
    end
  end

  defp usage("required"), do: :required
  defp usage(optional) when optional in [nil, "optional"], do: :optional

  # ---- simple types -----------------------------------------------------

  defp simple(%{children: children} = node, name, ctx, trail) do
    if name in trail, do: raise(ArgumentError, "recursive simple type #{name}")
    trail = if name, do: [name | trail], else: trail

    case for c <- children, c.tag != "annotation", do: c do
      [%{tag: "restriction"} = r] -> restriction(r, name, ctx, trail)
      [%{tag: tag}] -> raise ArgumentError, "unsupported simple type <#{tag}>"
      _other -> raise ArgumentError, "malformed simpleType #{inspect(node.attrs)}"
    end
  end

  defp restriction(%{attrs: attrs} = node, name, ctx, trail) do
    base =
      case attrs do
        %{"base" => base} -> base_leaf(base, node, ctx, trail)
        _inline -> inline_base(node, ctx, trail)
      end

    facets = for c <- node.children, c.tag not in ["annotation", "simpleType"], do: c
    apply_facets(%{base | name: name}, facets)
  end

  defp inline_base(node, ctx, trail) do
    [t] = for c <- node.children, c.tag == "simpleType", do: c
    simple(t, nil, ctx, trail)
  end

  defp base_leaf(base, node, ctx, trail) do
    {uri, local} = qname(base, node)

    cond do
      uri == @xsd_ns ->
        builtin_leaf(local, nil)

      uri == ctx.ns and is_map_key(ctx.simple, local) ->
        simple(ctx.simple[local], local, ctx, trail)

      true ->
        raise ArgumentError, "unknown simple base type #{base}"
    end
  end

  defp builtin_leaf(local, name) do
    case @builtins do
      %{^local => base} -> new_leaf(base, name)
      _ -> raise ArgumentError, "unsupported built-in type xs:#{local}"
    end
  end

  defp new_leaf(base, name) do
    %{
      base: base,
      name: name,
      pattern: nil,
      inherited_patterns: [],
      enum: nil,
      length: nil,
      min_length: nil,
      max_length: nil,
      total_digits: nil,
      fraction_digits: nil,
      white_space: nil,
      min_inclusive: nil,
      max_inclusive: nil,
      min_exclusive: nil,
      max_exclusive: nil
    }
  end

  defp apply_facets(leaf, facets) do
    grouped = Enum.group_by(facets, & &1.tag, & &1.attrs["value"])

    leaf
    |> put_pattern(Map.get(grouped, "pattern", []))
    |> put_enum(Map.get(grouped, "enumeration", []))
    |> then(&Enum.reduce(grouped, &1, fn {tag, values}, acc -> put_facet(acc, tag, values) end))
  end

  defp put_pattern(leaf, []), do: leaf

  defp put_pattern(%{pattern: nil} = leaf, patterns),
    do: %{leaf | pattern: join_patterns(patterns)}

  # A derived type that adds a pattern to an inherited one is an AND in XSD:
  # the value must match both. `pattern` keeps the most derived step and the
  # earlier steps move to `inherited_patterns` (nearest first).
  defp put_pattern(%{pattern: old} = leaf, patterns) do
    %{
      leaf
      | pattern: join_patterns(patterns),
        inherited_patterns: [old | leaf.inherited_patterns]
    }
  end

  defp join_patterns([one]), do: one
  defp join_patterns(many), do: Enum.map_join(many, "|", &("(" <> &1 <> ")"))

  defp put_enum(leaf, []), do: leaf
  defp put_enum(leaf, values), do: %{leaf | enum: values}

  defp put_facet(leaf, tag, [value]) when is_map_key(@facet_ints, tag) do
    Map.put(leaf, @facet_ints[tag], String.to_integer(value))
  end

  defp put_facet(leaf, tag, [value]) when is_map_key(@facet_strings, tag) do
    Map.put(leaf, @facet_strings[tag], value)
  end

  defp put_facet(leaf, "whiteSpace", [value]) when value in ~w(preserve replace collapse) do
    %{leaf | white_space: String.to_existing_atom(value)}
  end

  defp put_facet(leaf, tag, _values) when tag in ["pattern", "enumeration"], do: leaf

  defp put_facet(_leaf, tag, _values), do: raise(ArgumentError, "unsupported facet <#{tag}>")

  # ---- names ------------------------------------------------------------

  defp qname(value, %{nsmap: nsmap}) do
    case String.split(value, ":", parts: 2) do
      [local] ->
        {Map.get(nsmap, "", ""), local}

      [prefix, local] ->
        case nsmap do
          %{^prefix => uri} -> {uri, local}
          _ -> raise ArgumentError, "undeclared namespace prefix in #{value}"
        end
    end
  end

  # Trusted build-time input (a local XSD), so creating atoms is bounded.
  defp key(name), do: name |> snake_case() |> :erlang.binary_to_atom(:utf8)

  defp check_keys!(%{content: content, attrs: attrs, tag: tag}, path) do
    names = Enum.map(direct(content), & &1.tag) ++ Enum.map(attrs, &("@" <> &1.name))

    case collisions(names) do
      :ok ->
        :ok

      {:error, found} ->
        raise ArgumentError,
              "key collision under #{Enum.join(path, "/")} (#{tag}): #{inspect(found)}"
    end
  end

  defp direct(nil), do: []
  defp direct(%{base: _leaf}), do: []

  defp direct(%{kind: kind, children: children}) when kind in [:sequence, :choice],
    do: Enum.flat_map(children, &direct/1)

  defp direct(%{kind: kind} = node) when kind in [:element, :foreign], do: [node]

  @doc """
  Detects sibling key collisions in `names` (XSD names under one element;
  attributes are written `"@name"`). Returns `:ok` or
  `{:error, [{key_string, [names]}]}`.
  """
  @spec collisions([String.t()]) :: :ok | {:error, [{String.t(), [String.t()]}]}
  def collisions(names) do
    names
    |> Enum.uniq()
    |> Enum.group_by(&(&1 |> String.trim_leading("@") |> snake_case()))
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> case do
      [] -> :ok
      found -> {:error, Enum.sort(found)}
    end
  end

  @doc "Deterministic snake_case key of an XSD name (see the moduledoc)."
  @spec snake_case(String.t()) :: String.t()
  def snake_case(name) do
    ~r/[A-Z]+[0-9]*|[a-z]+[0-9]*|[0-9]+/
    |> Regex.scan(String.replace(name, "NFe", "NFE"))
    |> List.flatten()
    |> words()
    |> Enum.map_join("_", &String.downcase/1)
  end

  defp words([]), do: []

  defp words([<<first, _::binary>> = upper, <<l, _::binary>> = lower | rest])
       when first in ?A..?Z and l in ?a..?z do
    if String.length(upper) > 1 and not digit_end?(upper) do
      split_acronym(upper, lower) ++ words(rest)
    else
      [upper <> lower | words(rest)]
    end
  end

  defp words([word | rest]), do: [word | words(rest)]

  defp digit_end?(word), do: String.last(word) in ~w(0 1 2 3 4 5 6 7 8 9)

  defp split_acronym(upper, lower) do
    {head, last} = String.split_at(upper, -1)

    cond do
      parts = segment(head) -> parts ++ [last <> lower]
      parts = segment(upper) -> parts ++ [lower]
      true -> [head, last <> lower]
    end
  end

  defp segment(""), do: []

  defp segment(text) do
    Enum.find_value(@acronyms, fn acronym ->
      with true <- String.starts_with?(text, acronym),
           rest when is_list(rest) <- segment(String.replace_prefix(text, acronym, "")) do
        [acronym | rest]
      else
        _ -> nil
      end
    end)
  end
end
