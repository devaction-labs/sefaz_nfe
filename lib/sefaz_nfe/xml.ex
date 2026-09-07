defmodule SefazNfe.XML do
  @moduledoc """
  Reading side of the SEFAZ XML, on `:xmerl`.

  ## Safety

  The body arrives over the network, so parsing is hardened before `:xmerl`
  sees it. A DTD is rejected outright: SEFAZ never sends one, and accepting it
  is what opens both XXE and entity expansion (billion laughs). `:xmerl` has no
  budget for either, so refusing the construct is the defence rather than
  limiting it. External fetches are stubbed as a second layer, and a malformed
  body is an error rather than a crash — the network is allowed to be hostile.

  ## Encoding

  The body is handed to `:xmerl` as raw bytes, not as a decoded charlist.
  SEFAZ declares `encoding="utf-8"` and its messages are Portuguese — every
  rejection carries accents — so `:xmerl` must do the decoding itself. Passing
  already-decoded codepoints makes it decode twice and reject the document.

  Scanning is namespace conformant, which is what populates the namespace axis
  `SefazNfe.XML.C14N` needs to canonicalise a subtree for signing.

  ## Reading

  `text/2` and `attribute/3` take a local element name and ignore namespace
  prefixes. SEFAZ responses arrive prefixed differently per UF and per service,
  and matching on the local name is what keeps one parser working across all of
  them.
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

  @doctype ~r/<!(?:DOCTYPE|ENTITY)/i

  @type doc :: tuple()

  @doc """
  Parses `body` into an `:xmerl` document.

  Returns `{:error, {:xml, :dtd_forbidden}}` for a body carrying a DTD and
  `{:error, {:xml, :malformed}}` when `:xmerl` cannot read it.
  """
  @spec parse(binary()) :: {:ok, doc()} | {:error, {:xml, atom()}}
  def parse(body) when is_binary(body) do
    if Regex.match?(@doctype, body) do
      {:error, {:xml, :dtd_forbidden}}
    else
      scan(body)
    end
  end

  defp scan(body) do
    {doc, _rest} =
      :xmerl_scan.string(:binary.bin_to_list(body),
        quiet: true,
        namespace_conformant: true,
        fetch_fun: fn _uri, state -> {:ok, {:string, ~c""}, state} end
      )

    {:ok, doc}
  rescue
    _error -> {:error, {:xml, :malformed}}
  catch
    :exit, _reason -> {:error, {:xml, :malformed}}
  end

  @doc "Text content of the first element whose local name is `name`."
  @spec text(doc(), String.t()) :: String.t() | nil
  def text(doc, name) do
    case find(doc, name) do
      nil -> nil
      element -> element |> collect_text() |> List.flatten() |> List.to_string() |> String.trim()
    end
  end

  @doc "Text of `name` as an integer, or `nil` when absent or not numeric."
  @spec integer(doc(), String.t()) :: integer() | nil
  def integer(doc, name) do
    with value when is_binary(value) <- text(doc, name),
         {parsed, ""} <- Integer.parse(value) do
      parsed
    else
      _not_an_integer -> nil
    end
  end

  @doc "Every element whose local name is `name`."
  @spec all(doc(), String.t()) :: [doc()]
  def all(doc, name) do
    doc |> elements() |> Enum.filter(&(local_name(&1) == name))
  end

  @doc "Value of attribute `attr` on the first element named `name`."
  @spec attribute(doc(), String.t(), String.t()) :: String.t() | nil
  def attribute(doc, name, attr) do
    case find(doc, name) do
      nil ->
        nil

      element ->
        element |> xml_element(:attributes) |> Enum.find_value(&match_attribute(&1, attr))
    end
  end

  defp match_attribute(attribute, name) do
    if Atom.to_string(xml_attribute(attribute, :name)) == name do
      attribute |> xml_attribute(:value) |> List.to_string()
    end
  end

  @doc "The first element whose local name is `name`, as an `:xmerl` record."
  @spec element(doc(), String.t()) :: doc() | nil
  def element(doc, name), do: find(doc, name)

  @doc "Text of `element` itself, without searching its descendants."
  @spec own_text(doc()) :: String.t() | nil
  def own_text(element) do
    case element |> collect_text() |> List.flatten() |> List.to_string() |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  @doc "Attribute `attr` on `element` itself, without searching its descendants."
  @spec own_attribute(doc(), String.t()) :: String.t() | nil
  def own_attribute(element, attr) do
    element |> xml_element(:attributes) |> Enum.find_value(&match_attribute(&1, attr))
  end

  defp find(doc, name) do
    doc |> elements() |> Enum.find(&(local_name(&1) == name))
  end

  defp elements(xml_element(content: content) = element) do
    [element | Enum.flat_map(content, &elements/1)]
  end

  defp elements(_other), do: []

  defp local_name(element) do
    element |> xml_element(:name) |> Atom.to_string() |> String.split(":") |> List.last()
  end

  defp collect_text(xml_element(content: content)), do: Enum.map(content, &collect_text/1)
  defp collect_text(xml_text(value: value)), do: value
  defp collect_text(_other), do: []
end
