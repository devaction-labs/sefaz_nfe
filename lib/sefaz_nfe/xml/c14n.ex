defmodule SefazNfe.XML.C14N do
  @moduledoc """
  Canonical XML 1.0 without comments, the form XMLDSig digests.

  OTP ships no `xmerl_c14n`, so this is written here. Output is compared
  byte for byte against `xmllint --c14n` in the test suite: a canonicalisation
  that disagrees with the reference by one byte produces a valid-looking
  signature that SEFAZ rejects, and the failure gives no hint why.

  ## What the specification asks for

  Empty elements become a start and end tag pair, attribute values and text are
  escaped to a fixed set, namespace declarations come before attributes, and
  both are sorted — namespaces by prefix, attributes by namespace URI then
  local name.

  ## The apex rule

  A subtree being signed is canonicalised out of its document, so the top
  element must render every namespace it merely inherited. `infNFe` carries no
  `xmlns` of its own — the declaration sits on `NFe` — and omitting it there is
  the classic reason an NF-e signature verifies locally and is refused by
  SEFAZ. Descendants render only what differs from what an ancestor already
  rendered.

  This is Canonical XML 1.0, not the exclusive variant: every in-scope
  namespace is rendered, whether or not the subtree uses it.
  """

  require Record

  Record.defrecordp(
    :xml_element,
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xml_text,
    :xmlText,
    Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
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

  Record.defrecordp(
    :xml_pi,
    :xmlPI,
    Record.extract(:xmlPI, from_lib: "xmerl/include/xmerl.hrl")
  )

  @doc """
  Canonicalises `element` and everything under it.

  The element is treated as an apex: namespaces inherited from its ancestors
  are rendered on it.
  """
  @spec canonicalize(tuple()) :: binary()
  def canonicalize(element) do
    element |> render(%{}) |> IO.iodata_to_binary()
  end

  defp render(xml_element(content: content) = element, rendered) do
    name = qualified_name(element)
    {declarations, rendered} = namespaces(element, rendered)

    [
      ?<,
      name,
      declarations,
      attributes(element),
      ?>,
      Enum.map(content, &render(&1, rendered)),
      "</",
      name,
      ?>
    ]
  end

  defp render(xml_text(value: value), _rendered), do: escape_text(value)

  defp render(xml_pi(name: name, value: value), _rendered) do
    case List.to_string(value) do
      "" -> ["<?", Atom.to_string(name), "?>"]
      data -> ["<?", Atom.to_string(name), ?\s, data, "?>"]
    end
  end

  defp render(_comment_or_other, _rendered), do: []

  defp qualified_name(element) do
    element |> xml_element(:name) |> Atom.to_string()
  end

  defp namespaces(element, rendered) do
    xml_namespace(default: default, nodes: nodes) = xml_element(element, :namespace)

    in_scope =
      nodes
      |> Enum.map(fn {prefix, uri} -> {List.to_string(prefix), Atom.to_string(uri)} end)
      |> Map.new()
      |> put_default(default)

    fresh =
      for {prefix, uri} <- in_scope,
          Map.get(rendered, prefix) != uri,
          into: %{},
          do: {prefix, uri}

    declarations =
      fresh
      |> Enum.sort()
      |> Enum.map(fn
        {"", uri} -> [~s( xmlns="), escape_attribute_value(uri), ?"]
        {prefix, uri} -> [~s( xmlns:), prefix, ~s(="), escape_attribute_value(uri), ?"]
      end)

    {declarations, Map.merge(rendered, fresh)}
  end

  defp put_default(map, default) when default in [[], :undefined, nil], do: map
  defp put_default(map, default), do: Map.put(map, "", Atom.to_string(default))

  defp attributes(element) do
    element
    |> xml_element(:attributes)
    |> Enum.reject(&namespace_declaration?/1)
    |> Enum.map(&{sort_key(&1), &1})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_key, attribute} ->
      [
        ?\s,
        attribute |> xml_attribute(:name) |> Atom.to_string(),
        ~s(="),
        attribute |> xml_attribute(:value) |> escape_attribute_value(),
        ?"
      ]
    end)
  end

  defp namespace_declaration?(attribute) do
    case xml_attribute(attribute, :name) do
      :xmlns -> true
      name -> String.starts_with?(Atom.to_string(name), "xmlns:")
    end
  end

  # Namespace URI first, then local name — an unprefixed attribute is in no
  # namespace, and the empty URI sorts before every real one.
  defp sort_key(attribute) do
    case xml_attribute(attribute, :nsinfo) do
      {prefix, local} -> {uri_of(attribute, List.to_string(prefix)), List.to_string(local)}
      _none -> {"", attribute |> xml_attribute(:name) |> Atom.to_string()}
    end
  end

  defp uri_of(attribute, prefix) do
    case xml_attribute(attribute, :namespace) do
      xml_namespace(nodes: nodes) -> Enum.find_value(nodes, "", &match_prefix(&1, prefix))
      _absent -> ""
    end
  end

  defp match_prefix({candidate, uri}, prefix) do
    if List.to_string(candidate) == prefix, do: Atom.to_string(uri)
  end

  defp escape_text(value) do
    value
    |> List.to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\r", "&#xD;")
  end

  defp escape_attribute_value(value) when is_list(value),
    do: value |> List.to_string() |> escape_attribute_value()

  defp escape_attribute_value(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("\t", "&#x9;")
    |> String.replace("\n", "&#xA;")
    |> String.replace("\r", "&#xD;")
  end
end
