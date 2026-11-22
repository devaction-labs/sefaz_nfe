defmodule SefazNfe.Builder.Walker do
  @moduledoc false
  # The writing half of `SefazNfe.Builder`: walks a layout element together with
  # the caller's map and returns `{iodata, errors}`. `ctx` is the
  # `SefazNfe.Builder.Document` being written; it decides the fixed `versao` and
  # which modal layouts an `infModal` (`xs:any`) may hold, nothing else: order,
  # occurrence, choices and facets are the layout's.

  alias SefazNfe.Builder.Document
  alias SefazNfe.Builder.Leaf
  alias SefazNfe.Layout

  @doc "Writes `element` for `value`; `rpath` is the reversed path to it."
  @spec run(Document.t(), map(), term(), list()) :: {iodata(), [SefazNfe.Builder.error()]}
  def run(ctx, element, value, rpath \\ []), do: emit(ctx, element, value, rpath, 1, [])

  # An element ---------------------------------------------------------------
  #
  # `rpath` is the path to the element, reversed. `pos` is its 1-based position
  # in its list (nItem). Every clause returns `{iodata, errors}`.

  defp emit(_ctx, %{content: %{base: _} = leaf} = element, value, rpath, _pos, errors) do
    case Leaf.text(leaf, value) do
      {:ok, text} -> {[open(element, []), Leaf.escape(text), close(element)], errors}
      {:error, reason} -> {[], [error(rpath, reason) | errors]}
    end
  end

  defp emit(_ctx, %{content: nil} = element, true, _rpath, _pos, errors),
    do: {["<", element.tag, "/>"], errors}

  defp emit(ctx, %{content: content} = element, value, rpath, pos, errors)
       when content != nil and is_map(value) and not is_struct(value) do
    {input, errors} = normalize(ctx, value, element, rpath, errors)
    {attributes, errors} = attributes(ctx, element, input, rpath, pos, errors)
    {children, errors} = group(ctx, content, input, rpath, errors)

    {[open(element, attributes), children, close(element)], errors}
  end

  defp emit(_ctx, _element, _value, rpath, _pos, errors),
    do: {[], [error(rpath, :invalid_type) | errors]}

  defp open(element, attributes), do: ["<", element.tag, attributes, ">"]
  defp close(element), do: ["</", element.tag, ">"]

  # Keys ---------------------------------------------------------------------

  # Resolves the keys of `value` against the layout's own, so a string key never
  # creates an atom. The result has atom keys only.
  defp normalize(ctx, value, element, rpath, errors) do
    known = known_keys(ctx, element)

    Enum.reduce(value, {%{}, errors}, fn {given, content}, {acc, errors} ->
      case resolve(given, known) do
        nil ->
          {acc, [error([given | rpath], unknown(ctx, element, given)) | errors]}

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

  # The modals of the document are keys of the element that holds the `xs:any`.
  defp known_keys(ctx, %{attrs: attrs} = element),
    do: keys(element) ++ Enum.map(attrs, & &1.key) ++ modal_keys(ctx, element)

  defp modal_keys(ctx, element), do: if(any?(element), do: Map.keys(ctx.modals), else: [])

  # A modal of the family with no layout (only the road ones have one) is not a
  # typo: it is named as unsupported.
  defp unknown(ctx, element, given) do
    case any?(element) && Document.modal_key(ctx, given) do
      {:unsupported, key} -> {:unsupported_modal, key}
      _other -> :unknown_key
    end
  end

  defp any?(%{content: %{kind: kind, children: children}}) when kind in [:sequence, :choice],
    do: Enum.any?(children, &(&1.kind == :any))

  defp any?(_element), do: false

  # The element keys directly inside a node, looking through groups.
  defp keys(node) do
    for %{kind: :element, key: key} <- Layout.elements(node), do: key
  end

  defp present?(input, key), do: Map.get(input, key) != nil

  # Attributes ---------------------------------------------------------------

  defp attributes(ctx, %{attrs: attrs} = element, input, rpath, pos, errors) do
    attrs
    |> Enum.sort_by(& &1.name)
    |> Enum.map_reduce(errors, fn attribute, errors ->
      given = Map.get(input, attribute.key)
      attribute(ctx, element, attribute, given, [attribute.key | rpath], pos, errors)
    end)
  end

  # versao is fixed per document; nItem is the position, not something the
  # caller computes.
  defp attribute(
         %{inf: inf, versao: versao},
         %{key: inf},
         %{key: :versao} = attribute,
         nil,
         rpath,
         _pos,
         errors
       ),
       do: attribute_text(attribute, versao, rpath, errors)

  defp attribute(_ctx, %{key: :det}, %{key: :n_item} = attribute, given, rpath, pos, errors) do
    expected = Integer.to_string(pos)

    case given do
      nil -> attribute_text(attribute, expected, rpath, errors)
      ^pos -> attribute_text(attribute, expected, rpath, errors)
      ^expected -> attribute_text(attribute, expected, rpath, errors)
      _other -> {[], [error(rpath, {:invalid_n_item, pos}) | errors]}
    end
  end

  defp attribute(_ctx, _element, %{fixed: fixed} = attribute, nil, rpath, _pos, errors)
       when is_binary(fixed),
       do: attribute_text(attribute, fixed, rpath, errors)

  defp attribute(_ctx, _element, %{use: :required}, nil, rpath, _pos, errors),
    do: {[], [error(rpath, :required) | errors]}

  defp attribute(_ctx, _element, _attribute, nil, _rpath, _pos, errors), do: {[], errors}

  defp attribute(_ctx, _element, attribute, given, rpath, _pos, errors),
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
  defp group(ctx, %{kind: :sequence, min: 0} = sequence, input, rpath, errors) do
    if Enum.any?(keys(sequence), &present?(input, &1)),
      do: members(ctx, sequence, input, rpath, errors),
      else: {[], errors}
  end

  defp group(ctx, %{kind: :sequence} = sequence, input, rpath, errors),
    do: members(ctx, sequence, input, rpath, errors)

  defp group(ctx, %{kind: :choice} = choice, input, rpath, errors) do
    given = choice |> keys() |> Enum.uniq() |> Enum.filter(&present?(input, &1))

    case given do
      [] -> choice_none(choice, rpath, errors)
      _ -> choice_branch(ctx, choice, given, input, rpath, errors)
    end
  end

  defp members(ctx, %{children: children}, input, rpath, errors) do
    Enum.map_reduce(children, errors, fn
      %{kind: :element} = element, errors -> child(ctx, element, input, rpath, errors)
      %{kind: :foreign}, errors -> {[], errors}
      %{kind: :any} = any, errors -> modal(ctx, any, input, rpath, errors)
      group, errors -> group(ctx, group, input, rpath, errors)
    end)
  end

  # The `xs:any` of `infModal`: exactly one modal, whose layout is the one the
  # key names, walked like any other element. Its elements are in the document's
  # own namespace (the XSDs share the target namespace), so they are written
  # with no declaration of their own.
  defp modal(ctx, any, input, rpath, errors) do
    case for(key <- Map.keys(ctx.modals), present?(input, key), do: key) do
      [] when any.min == 0 ->
        {[], errors}

      [] ->
        {[], [error(rpath, :choice_none) | errors]}

      [key] ->
        layout = Layout.modal(Map.fetch!(ctx.modals, key))
        emit(ctx, layout.root, Map.fetch!(input, key), [key | rpath], 1, errors)

      several ->
        {[], [error(rpath, {:choice_many, Enum.sort(several)}) | errors]}
    end
  end

  defp choice_none(choice, rpath, errors) do
    if choice.min == 0 or Enum.any?(choice.children, &nullable?/1),
      do: {[], errors},
      else: {[], [error(rpath, :choice_none) | errors]}
  end

  defp choice_branch(ctx, choice, given, input, rpath, errors) do
    branches = Enum.filter(choice.children, &(&1.kind != :foreign and given -- keys_of(&1) == []))

    case branches do
      [%{kind: :element} = element] -> child(ctx, element, input, rpath, errors)
      [branch] -> group(ctx, branch, input, rpath, errors)
      [] -> {[], [error(rpath, {:choice_many, given}) | errors]}
      _several -> {[], [error(rpath, {:choice_ambiguous, given}) | errors]}
    end
  end

  defp keys_of(%{kind: :element, key: key}), do: [key]
  defp keys_of(%{kind: :any}), do: []
  defp keys_of(group), do: keys(group)

  defp nullable?(%{kind: :element, min: min}), do: min == 0
  defp nullable?(%{kind: :sequence, min: 0}), do: true
  defp nullable?(%{kind: :sequence, children: children}), do: Enum.all?(children, &nullable?/1)
  defp nullable?(%{kind: :choice, min: 0}), do: true
  defp nullable?(%{kind: :choice, children: children}), do: Enum.any?(children, &nullable?/1)
  defp nullable?(%{kind: :foreign, min: min}), do: min == 0
  defp nullable?(%{kind: :any, min: min}), do: min == 0

  # Occurrence ---------------------------------------------------------------

  defp child(ctx, %{key: key, min: min} = element, input, rpath, errors) do
    case Map.get(input, key) do
      nil when min == 0 -> {[], errors}
      nil -> {[], [error([key | rpath], :required) | errors]}
      value -> occurs(ctx, element, value, [key | rpath], errors)
    end
  end

  defp occurs(ctx, %{max: 1} = element, value, rpath, errors),
    do: emit(ctx, element, value, rpath, 1, errors)

  defp occurs(ctx, element, items, rpath, errors) when is_list(items) do
    count = length(items)

    errors =
      if count < element.min or (element.max != :unbounded and count > element.max),
        do: [error(rpath, {:occurs, element.min, element.max, count}) | errors],
        else: errors

    items
    |> Enum.with_index()
    |> Enum.map_reduce(errors, fn {item, index}, errors ->
      emit(ctx, element, item, [index | rpath], index + 1, errors)
    end)
  end

  defp occurs(_ctx, _element, _value, rpath, errors),
    do: {[], [error(rpath, :not_a_list) | errors]}

  defp error(rpath, reason), do: {Enum.reverse(rpath), reason}
end
