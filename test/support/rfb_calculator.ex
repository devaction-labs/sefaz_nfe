defmodule SefazNfe.RFBCalculator do
  @moduledoc false
  # Test support for the conformance golden against the official Receita Federal
  # calculators (`test/golden/rfb/README.md`).
  #
  # Shared by `test/sefaz_nfe/rfb_calculator_golden_test.exs` (reads committed files,
  # never a socket) and `scripts/conformance/render_rfb.exs` (talks to the
  # calculators). The library never computes a tax: every number of the document
  # built here is a string the calculator wrote.

  alias SefazNfe.Builder
  alias SefazNfe.Layout.Generator
  alias SefazNfe.NFeBuilder
  alias SefazNfe.NFeMap
  alias SefazNfe.XML
  alias SefazNfe.XML.C14N

  @dir Path.expand("../golden/rfb", __DIR__)
  @namespace "http://www.portalfiscal.inf.br/nfe"

  # Not elements of PL_010_V1.30: the free text the calculator adds for humans, and
  # `pISEspec`, which the calculator's newer layout (NT v1.36) writes where the PL
  # has `adRemIS` (the result carries both; see `@differences` in the golden test).
  @dropped ["memoriaCalculo", "pISEspec"]

  @doc "The golden directory (`test/golden/rfb`)."
  @spec dir() :: String.t()
  def dir, do: @dir

  @doc "Names of the scenarios, sorted."
  @spec names() :: [String.t()]
  def names do
    @dir
    |> Path.join("scenarios/*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.sort()
  end

  @doc "The scenario: a map with the keys `meta` and `request`."
  @spec scenario(String.t()) :: map()
  def scenario(name), do: read_json("scenarios/#{name}.json")

  @doc "The calculator's result (the ROC for `roc` scenarios, which is its own input)."
  @spec expected_result(String.t()) :: map()
  def expected_result(name), do: read_json("expected/#{name}.json")

  @doc "The XML the calculator's `xml/generate` wrote, or `nil` (Simples Nacional has none)."
  @spec expected_xml(String.t()) :: String.t() | nil
  def expected_xml(name), do: read_text("expected/#{name}.xml")

  @doc "The verdict the calculator's `xml/validate` gave our fragment, or `nil`."
  @spec expected_validation(String.t()) :: map() | nil
  def expected_validation(name) do
    if File.exists?(Path.join(@dir, "expected/#{name}.validation.json")),
      do: read_json("expected/#{name}.validation.json")
  end

  @doc "Names of the scenarios whose result is an NF-e group (not Simples Nacional)."
  @spec group_names() :: [String.t()]
  def group_names, do: Enum.filter(names(), &(scenario(&1)["meta"]["kind"] != "simples"))

  defp read_json(path), do: path |> read_text() |> JSON.decode!()

  defp read_text(path) do
    file = Path.join(@dir, path)
    if File.exists?(file), do: File.read!(file)
  end

  @doc """
  Our NF-e: a minimal document whose IS and IBS/CBS groups are the calculator's
  `result`, key by key. Returns what `SefazNfe.Builder.build_nfe/1` returns.
  """
  @spec build(map(), map()) :: {:ok, map()} | {:error, term()}
  def build(%{"meta" => meta}, result),
    do: result |> builder_map(model(meta)) |> Builder.build_nfe()

  @doc "The builder input for `result`, as a map (see `build/2`)."
  @spec builder_map(map(), 55 | 65) :: map()
  def builder_map(result, model) do
    # The builder writes the key (and `cNF`, `cDV`) itself.
    document =
      model
      |> NFeMap.document(3, NFeBuilder.build(model: model).access_key)
      |> Map.delete(:id)
      |> update_in([:ide], &Map.drop(&1, [:c_nf, :c_dv]))

    [det | _] = document.det

    items =
      for object <- Enum.sort_by(result["objetos"], & &1["nObj"]) do
        imposto =
          det.imposto
          |> Map.delete(:ibs_cbs)
          |> Map.merge(item_groups(object["tribCalc"]))

        %{det | imposto: imposto}
      end

    %{document | det: items, total: total(document.total, result["total"]["tribCalc"])}
    |> put_compra_gov(result["oper"])
  end

  defp model(%{"document" => "nfce"}), do: 65
  defp model(%{"document" => "nfe"}), do: 55

  defp item_groups(trib_calc) do
    for {name, key} <- [{"IS", "is"}, {"IBSCBS", "ibs_cbs"}],
        group = trib_calc[name],
        into: %{},
        do: {key, keys(group)}
  end

  defp total(base, trib_calc) do
    for {name, key} <- [{"ISTot", "is_tot"}, {"IBSCBSTot", "ibs_cbs_tot"}],
        group = trib_calc[name],
        reduce: Map.delete(base, :ibs_cbs_tot) do
      acc -> Map.put(acc, key, keys(group))
    end
  end

  defp put_compra_gov(document, %{"gCompraGov" => group}),
    do: put_in(document, [:ide, "g_compra_gov"], keys(group))

  defp put_compra_gov(document, _oper), do: document

  # The calculator names elements as the PL does; the builder wants the layout's
  # keys. `Generator.snake_case/1` is the layout's own rule, so nothing is mapped
  # by hand. Strings stay strings: the builder validates them, the library never
  # parses a number out of them.
  defp keys(map) when is_map(map) do
    for {name, value} <- map, name not in @dropped, into: %{} do
      {Generator.snake_case(name), keys(value)}
    end
  end

  defp keys(list) when is_list(list), do: Enum.map(list, &keys/1)
  defp keys(value), do: value

  @doc """
  The fragments both sides are compared on, in document order:
  `{label, canonical_form}`. Whitespace between elements is not content.
  """
  @spec fragments(String.t()) :: [{String.t(), String.t()}]
  def fragments(xml) do
    {:ok, doc} = xml |> String.replace(~r/>\s+</, "><") |> XML.parse()
    inf = XML.element(doc, "infNFe")

    ide = for e <- named(inf, "ide"), g <- named(e, "gCompraGov"), do: {"ide/gCompraGov", g}

    det =
      for {d, n} <- inf |> named("det") |> Enum.with_index(1),
          imposto <- named(d, "imposto"),
          group <- named(imposto, "IS") ++ named(imposto, "IBSCBS"),
          do: {"det[#{n}]/imposto/#{local(group)}", group}

    total =
      for t <- named(inf, "total"),
          group <- named(t, "ISTot") ++ named(t, "IBSCBSTot"),
          do: {"total/#{local(group)}", group}

    for {label, element} <- ide ++ det ++ total, do: {label, C14N.canonicalize(element)}
  end

  defp named(element, name), do: element |> XML.children() |> Enum.filter(&(local(&1) == name))
  defp local(element), do: element |> XML.qname() |> elem(1)

  @doc """
  The fragments of `xml` as the `infNFe` the calculator's `subtipo=grupo`
  validation takes (the shape `xml/generate` writes).
  """
  @spec group_xml(String.t()) :: String.t()
  def group_xml(xml) do
    fragments = fragments(xml)

    dets =
      fragments
      |> Enum.filter(fn {label, _} -> String.starts_with?(label, "det[") end)
      |> Enum.group_by(
        fn {label, _} -> Regex.run(~r/^det\[(\d+)\]/, label, capture: :all_but_first) end,
        fn {_, fragment} -> fragment end
      )
      |> Enum.sort_by(fn {[n], _} -> String.to_integer(n) end)
      |> Enum.map(fn {[n], groups} ->
        ~s(<det nItem="#{n}"><imposto>#{Enum.join(groups)}</imposto></det>)
      end)

    IO.iodata_to_binary([
      ~s(<infNFe xmlns="#{@namespace}">),
      wrap(fragments, "ide/", "ide"),
      dets,
      wrap(fragments, "total/", "total"),
      "</infNFe>"
    ])
  end

  defp wrap(fragments, prefix, tag) do
    groups = for {label, fragment} <- fragments, String.starts_with?(label, prefix), do: fragment
    if groups == [], do: "", else: "<#{tag}>#{Enum.join(groups)}</#{tag}>"
  end

  @doc "The first place two canonical fragments differ, as two short excerpts."
  @spec first_difference(String.t(), String.t()) :: {String.t(), String.t()}
  def first_difference(a, b) do
    from = max(common_prefix(a, b, 0) - 60, 0)

    {binary_part(a, from, min(200, byte_size(a) - from)),
     binary_part(b, from, min(200, byte_size(b) - from))}
  end

  defp common_prefix(<<c, a::binary>>, <<c, b::binary>>, n), do: common_prefix(a, b, n + 1)
  defp common_prefix(_a, _b, n), do: n
end
