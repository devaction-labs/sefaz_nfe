defmodule SefazNfe.Builder.Parser do
  @moduledoc false
  # The reading half of `SefazNfe.Builder` (`Builder.parse_nfe/2` and its CT-e,
  # CT-e OS and MDF-e siblings, one `SefazNfe.Builder.Document` each). It walks the
  # same layout tree the builder writes from, over the `:xmerl` tree of
  # `SefazNfe.XML` (DTD refused, namespace aware), so the keys it returns are
  # the builder's keys and nothing is invented: every key comes from the layout,
  # never from the document, and no atom is created.

  alias SefazNfe.Builder.Document
  alias SefazNfe.Layout
  alias SefazNfe.XML

  @dsig "http://www.w3.org/2000/09/xmldsig#"

  # infProt children, as keys. The protocol is SEFAZ's, not the layout's, so
  # its (small, fixed) shape is listed here.
  @protocol_keys %{
    "tpAmb" => :tp_amb,
    "verAplic" => :ver_aplic,
    "chNFe" => :ch_nfe,
    "chCTe" => :ch_cte,
    "chMDFe" => :ch_mdfe,
    "dhRecbto" => :dh_recbto,
    "nProt" => :n_prot,
    "digVal" => :dig_val,
    "cStat" => :c_stat,
    "xMotivo" => :x_motivo,
    "cMsg" => :c_msg,
    "xMsg" => :x_msg
  }

  @spec parse(Document.kind(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def parse(kind, xml, opts) when is_binary(xml) do
    document = Document.get(kind)

    ctx = %{
      document: document,
      layout: document.layout,
      modals: Document.modals_by_tag(document),
      strict: Keyword.get(opts, :strict, true),
      decimals: Keyword.get(opts, :decimals, false)
    }

    with :ok <- check_options(ctx),
         {:ok, doc} <- XML.parse(xml) do
      document(doc, ctx)
    end
  end

  defp check_options(%{decimals: true}) do
    if Code.ensure_loaded?(Decimal), do: :ok, else: {:error, :decimal_not_loaded}
  end

  defp check_options(_ctx), do: :ok

  # The document -------------------------------------------------------------

  defp document(doc, ctx) do
    namespace = ctx.layout.namespace
    %{root: root, proc: proc} = ctx.document

    case XML.qname(doc) do
      {^namespace, ^root} ->
        with {:ok, result} <- nfe(doc, ctx), do: {:ok, Map.put(result, :protocol, nil)}

      {^namespace, ^proc} ->
        nfe_proc(doc, ctx)

      {_namespace, name} ->
        {:error, {:unexpected_root, name}}
    end
  end

  defp nfe_proc(doc, ctx) do
    namespace = ctx.layout.namespace
    children = XML.children(doc)

    with {:ok, nfe_doc} <- single(children, namespace, ctx.document.root),
         {:ok, result} <- nfe(nfe_doc, ctx),
         {:ok, protocol} <- protocol(children, namespace, ctx.document.prot) do
      {:ok, %{result | protocol: protocol}}
    end
  end

  defp single(children, namespace, name) do
    case Enum.filter(children, &(XML.qname(&1) == {namespace, name})) do
      [one] -> {:ok, one}
      [] -> {:error, {:missing_element, name}}
      _several -> {:error, {:duplicate_element, name}}
    end
  end

  defp protocol(children, namespace, name) do
    case Enum.filter(children, &(XML.qname(&1) == {namespace, name})) do
      [] -> {:ok, nil}
      [prot] -> {:ok, protocol_map(prot)}
      _several -> {:error, {:duplicate_element, name}}
    end
  end

  defp protocol_map(prot) do
    inf_prot = Enum.find(XML.children(prot), &(elem(XML.qname(&1), 1) == "infProt"))

    fields =
      for child <- (inf_prot && XML.children(inf_prot)) || [],
          {_uri, name} = XML.qname(child),
          {:ok, key} <- [Map.fetch(@protocol_keys, name)],
          into: %{},
          do: {key, XML.raw_text(child)}

    fields
    |> put_attribute(prot, "versao", :versao)
    |> put_attribute(inf_prot, "Id", :id)
  end

  defp put_attribute(map, nil, _name, _key), do: map

  defp put_attribute(map, element, name, key) do
    case XML.own_attribute(element, name) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp nfe(doc, ctx) do
    with {:ok, map} <- element(ctx.layout.root, doc, [], ctx) do
      {unknown, map} = Map.pop(map, :__unknown__)

      %{result: result_key, inf: inf, supl: supl} = ctx.document

      result = %{
        result_key => Map.get(map, inf),
        supl: Map.get(map, supl),
        protocol: nil,
        signed?: Enum.any?(XML.children(doc), &(XML.qname(&1) == {@dsig, "Signature"}))
      }

      {:ok, if(unknown, do: Map.put(result, :__unknown__, unknown), else: result)}
    end
  end

  # An element ---------------------------------------------------------------

  defp element(%{content: %{base: _} = leaf}, xml, _path, ctx),
    do: {:ok, leaf_value(leaf, XML.raw_text(xml), ctx)}

  defp element(%{content: nil}, _xml, _path, _ctx), do: {:ok, true}

  defp element(%{attrs: attrs} = layout, xml, path, ctx) do
    with {:ok, attributes, unknown_attrs} <- attributes(attrs, xml, path, ctx),
         {:ok, children, unknown} <- children(layout, xml, path, ctx) do
      map = Map.merge(attributes, children)
      {:ok, put_unknown(map, Map.merge(unknown_attrs, unknown))}
    end
  end

  defp put_unknown(map, unknown) when map_size(unknown) == 0, do: map
  defp put_unknown(map, unknown), do: Map.put(map, :__unknown__, unknown)

  # Leaves -------------------------------------------------------------------

  defp leaf_value(%{base: :integer}, text, %{decimals: true}) do
    case Integer.parse(text) do
      {integer, ""} -> integer
      _not_an_integer -> text
    end
  end

  # `Decimal.parse/1` only sees text that is already a plain, short decimal
  # (no exponent, no sign, no "inf"/"NaN"); anything else stays the string, the
  # same as text that is not a decimal at all (the parser never rejects a leaf).
  defp leaf_value(%{name: "TDec" <> _}, text, %{decimals: true}) do
    case Regex.match?(~r/\A[0-9]{1,40}(\.[0-9]{1,40})?\z/, text) do
      true ->
        {decimal, ""} = Decimal.parse(text)
        decimal

      false ->
        text
    end
  end

  defp leaf_value(_leaf, text, _ctx), do: text

  # Attributes ---------------------------------------------------------------

  defp attributes(attrs, xml, path, ctx) do
    Enum.reduce_while(XML.attributes(xml), {:ok, %{}, %{}}, fn {name, value},
                                                               {:ok, known, other} ->
      case Enum.find(attrs, &(&1.name == name)) do
        nil when ctx.strict ->
          {:halt, {:error, {:unknown_attribute, Enum.reverse([name | path])}}}

        nil ->
          {:cont, {:ok, known, Map.put(other, "@" <> name, value)}}

        attribute ->
          {:cont, {:ok, Map.put(known, attribute.key, value), other}}
      end
    end)
  end

  # Children -----------------------------------------------------------------

  # `path` is reversed, like the builder's. The state carries the parsed
  # children in document order, how many of each key were seen (for the index
  # in a path) and what the layout did not know.
  defp children(layout, xml, path, ctx) do
    known = Map.new(Layout.elements(layout), &{&1.tag, &1})
    known = if any?(layout), do: Map.merge(known, modal_elements(ctx)), else: known
    initial = {:ok, {[], %{}, %{}}}

    result =
      Enum.reduce_while(XML.children(xml), initial, fn child, {:ok, state} ->
        case child(child, known, state, path, ctx) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, {pairs, _counts, unknown}} <- result,
         {:ok, map} <- group(Enum.reverse(pairs), path) do
      {:ok, map, unknown}
    end
  end

  # The modal elements an `infModal` may hold, found by tag like any child. The
  # `:modal_parent` mark tells `child/5` that a tag it does not know here is a
  # modal this library has no layout for.
  defp modal_elements(ctx) do
    modals =
      Map.new(ctx.modals, fn {tag, {_key, layout}} ->
        {tag, %{kind: :modal, root: layout.root, namespace: layout.namespace}}
      end)

    Map.put(modals, :modal_parent, true)
  end

  defp any?(%{content: %{kind: kind, children: children}}) when kind in [:sequence, :choice],
    do: Enum.any?(children, &(&1.kind == :any))

  defp any?(_layout), do: false

  defp child(xml, known, {pairs, counts, unknown} = state, path, ctx) do
    {namespace, tag} = XML.qname(xml)

    case Map.get(known, tag) do
      %{kind: :element} = layout when namespace == ctx.layout.namespace ->
        index = Map.get(counts, layout.key, 0)
        rpath = child_path(layout, index, path)

        with {:ok, value} <- element(layout, xml, rpath, ctx) do
          {:ok, {[{layout, value} | pairs], Map.put(counts, layout.key, index + 1), unknown}}
        end

      %{kind: :foreign, ns: ^namespace} ->
        {:ok, state}

      %{kind: :modal, root: root, namespace: ^namespace} ->
        with {:ok, value} <- element(root, xml, [root.key | path], ctx) do
          {:ok, {[{root, value} | pairs], counts, unknown}}
        end

      _other when ctx.strict and is_map_key(known, :modal_parent) ->
        {:error, {:unsupported_modal, tag}}

      _other when ctx.strict ->
        {:error, {:unknown_element, Enum.reverse([tag | path])}}

      _other ->
        {:ok,
         {pairs, counts, Map.update(unknown, tag, plain(xml), &(List.wrap(&1) ++ [plain(xml)]))}}
    end
  end

  # An element of a list is `[... key, index]`; a single one is `[... key]`.
  defp child_path(%{max: 1} = layout, _index, path), do: [layout.key | path]
  defp child_path(layout, index, path), do: [index, layout.key | path]

  defp group(pairs, path) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {layout, value}, {:ok, map} ->
      case layout do
        %{max: 1} when is_map_key(map, layout.key) ->
          {:halt, {:error, {:duplicate_element, Enum.reverse([layout.key | path])}}}

        %{max: 1} ->
          {:cont, {:ok, Map.put(map, layout.key, value)}}

        _list ->
          {:cont, {:ok, Map.update(map, layout.key, [value], &[value | &1])}}
      end
    end)
    |> case do
      {:ok, map} -> {:ok, Map.new(map, &finish/1)}
      error -> error
    end
  end

  defp finish({key, value}) when is_list(value), do: {key, Enum.reverse(value)}
  defp finish(pair), do: pair

  # What the layout does not know, as raw text: a leaf is its text, anything
  # with children is a map by tag (repeated tags are a list).
  defp plain(xml) do
    case XML.children(xml) do
      [] ->
        XML.raw_text(xml)

      children ->
        Enum.reduce(children, %{}, fn child, acc ->
          {_namespace, tag} = XML.qname(child)
          Map.update(acc, tag, plain(child), &(List.wrap(&1) ++ [plain(child)]))
        end)
    end
  end
end
