defmodule SefazNfe.Builder.Document do
  @moduledoc false
  # What differs between the documents the builder writes and reads (AD-024,
  # AD-026): which layout, the element names around `infXxx`, and the fields of
  # the access key. Everything else (order, occurrence, facets) is the layout's.
  #
  # `number` and `code` are the `ide` keys of the document number (`nNF`, `nCT`,
  # `nMDF`) and of the random code (`cNF`, `cCT`, `cMDF`); `AccessKey` calls them
  # `n_nf` and `c_nf` whatever the document. `modals` maps the input key of an
  # `infModal` content to its layout.

  alias SefazNfe.Layout

  @type kind :: :nfe | :cte | :cte_os | :mdfe

  @type t :: %{
          kind: kind(),
          layout: Layout.layout(),
          root: String.t(),
          root_versao: String.t() | nil,
          proc: String.t(),
          prot: String.t(),
          inf: atom(),
          supl: atom(),
          result: atom(),
          prefix: String.t(),
          versao: String.t(),
          number: atom(),
          code: atom(),
          modals: %{atom() => Layout.modal()}
        }

  # The modal elements of the CT-e and MDF-e families. Only the road ones have a
  # layout; any other is reported as unsupported, not as an unknown key.
  @modal_names ~w(rodo rodo_os aereo aquav ferrov duto multimodal)

  @spec get(kind()) :: t()
  def get(:nfe) do
    %{
      kind: :nfe,
      layout: Layout.nfe(),
      root: "NFe",
      root_versao: nil,
      proc: "nfeProc",
      prot: "protNFe",
      inf: :inf_nfe,
      supl: :inf_nfe_supl,
      result: :nfe,
      prefix: "NFe",
      versao: "4.00",
      number: :n_nf,
      code: :c_nf,
      modals: %{}
    }
  end

  def get(:cte) do
    %{
      kind: :cte,
      layout: Layout.cte(),
      root: "CTe",
      root_versao: nil,
      proc: "cteProc",
      prot: "protCTe",
      inf: :inf_cte,
      supl: :inf_cte_supl,
      result: :cte,
      prefix: "CTe",
      versao: "4.00",
      number: :n_ct,
      code: :c_ct,
      modals: %{rodo: :cte_rodo}
    }
  end

  def get(:cte_os) do
    %{
      kind: :cte_os,
      layout: Layout.cte_os(),
      root: "CTeOS",
      root_versao: "4.00",
      proc: "cteOSProc",
      prot: "protCTe",
      inf: :inf_cte,
      supl: :inf_cte_supl,
      result: :cte_os,
      prefix: "CTe",
      versao: "4.00",
      number: :n_ct,
      code: :c_ct,
      modals: %{rodo_os: :cte_os_rodo}
    }
  end

  def get(:mdfe) do
    %{
      kind: :mdfe,
      layout: Layout.mdfe(),
      root: "MDFe",
      root_versao: nil,
      proc: "mdfeProc",
      prot: "protMDFe",
      inf: :inf_mdfe,
      supl: :inf_mdfe_supl,
      result: :mdfe,
      prefix: "MDFe",
      versao: "3.00",
      number: :n_mdf,
      code: :c_mdf,
      modals: %{rodo: :mdfe_rodo}
    }
  end

  @doc """
  The modal input key a caller's key stands for: `{:supported, key}`,
  `{:unsupported, key}` for a modal of the family without a layout, or `:error`.
  Never creates an atom: strings are matched against the known names.
  """
  @spec modal_key(t(), term()) :: {:supported, atom()} | {:unsupported, atom()} | :error
  def modal_key(%{modals: modals}, given) when is_atom(given) or is_binary(given) do
    name = to_string(given)

    case Enum.find(Map.keys(modals), &(Atom.to_string(&1) == name)) do
      nil -> if name in @modal_names, do: {:unsupported, given}, else: :error
      key -> {:supported, key}
    end
  end

  def modal_key(_document, _given), do: :error

  @doc "The modal layouts of `document`, keyed by the tag of their root element."
  @spec modals_by_tag(t()) :: %{String.t() => {atom(), Layout.layout()}}
  def modals_by_tag(%{modals: modals}) do
    Map.new(modals, fn {key, name} ->
      layout = Layout.modal(name)
      {layout.root.tag, {key, layout}}
    end)
  end
end
