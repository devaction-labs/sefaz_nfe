defmodule SefazNfe.Builder.Index do
  @moduledoc false
  # Compile-time facts about the layout that `SefazNfe.Builder.Leaf` embeds as
  # literals, so a build never compiles a regex or re-derives a type's places.

  alias SefazNfe.Builder.Pattern
  alias SefazNfe.Layout

  @doc """
  Every leaf type of every layout the builder walks (the NF-e, CT-e, CT-e OS and
  MDF-e documents and the road modals; elements and attributes), unique.
  """
  @spec leaves() :: [map()]
  def leaves do
    layouts =
      [Layout.nfe(), Layout.cte(), Layout.cte_os(), Layout.mdfe()] ++
        Enum.map([:cte_rodo, :cte_os_rodo, :mdfe_rodo], &Layout.modal/1)

    layouts |> Enum.flat_map(&collect(&1.root, [])) |> Enum.uniq()
  end

  @doc "Every XSD pattern string in the layout, own and inherited."
  @spec patterns() :: [String.t()]
  def patterns do
    leaves()
    |> Enum.flat_map(&[&1.pattern | &1.inherited_patterns])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Decimal places per `TDec*` type name (the same name has the same places in
  every layout), as `{minimum, maximum}` with at least
  one place. They are not in the facets (the NF-e decimals are patterned
  strings), so they are probed: `1.1`, `1.11`, ... is run through the type's
  own patterns and the first and last length that match are kept.
  """
  @spec decimal_places() :: %{String.t() => {pos_integer(), pos_integer()}}
  def decimal_places do
    for %{name: "TDec" <> _ = name} = leaf <- leaves(), into: %{} do
      regexes = for p <- [leaf.pattern | leaf.inherited_patterns], p, do: Pattern.compile!(p)

      allowed =
        Enum.filter(1..12, fn places ->
          probe = "1." <> String.duplicate("1", places)
          Enum.all?(regexes, &Regex.match?(&1, probe))
        end)

      {name, {List.first(allowed), List.last(allowed)}}
    end
  end

  defp collect(%{kind: :element} = element, acc) do
    acc = Enum.reduce(element.attrs, acc, &[&1.type | &2])
    collect(element.content, acc)
  end

  defp collect(%{kind: kind, children: children}, acc) when kind in [:sequence, :choice],
    do: Enum.reduce(children, acc, &collect/2)

  defp collect(%{base: _} = leaf, acc), do: [leaf | acc]
  defp collect(_other, acc), do: acc
end
