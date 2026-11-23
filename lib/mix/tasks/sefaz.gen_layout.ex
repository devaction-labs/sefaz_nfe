defmodule Mix.Tasks.Sefaz.GenLayout do
  @shortdoc "Generates priv/layouts/nfe_4.00.etf from an official PL (XSD package)"

  @moduledoc """
  Compiles the NF-e `TNFe` type of an official Pacote de Liberacao into the
  ordered layout tree the builder walks (AD-024).

      mix sefaz.gen_layout PATH
      mix sefaz.gen_layout PATH --root TNFe --out priv/layouts/nfe_4.00.etf
      mix sefaz.gen_layout PATH --entry nfe_v4.00.xsd

  `PATH` is the directory of the NF-e schemas of the PL. The portal's package
  nests them in `NFe/` (`PL_010h_v1.03/NFe`), and the layout records the package
  name (`PL_010h_v1.03`), not `NFe`. The task
  follows `xs:include` / `xs:import` from `--entry` (default
  `nfe_v4.00.xsd`), compiles the complex type `--root` (default `TNFe`) and
  writes `--out` (default `priv/layouts/nfe_4.00.etf`).

  `--element NAME` compiles a global element instead of a type (a modal such
  as `rodo`, whose type is anonymous). The CT-e, CT-e OS and MDF-e layouts:

      mix sefaz.gen_layout CTE_PL --entry cte_v4.00.xsd --root TCTe --out priv/layouts/cte_4.00.etf
      mix sefaz.gen_layout CTE_PL --entry cteOS_v4.00.xsd --root TCTeOS --out priv/layouts/cte_os_4.00.etf
      mix sefaz.gen_layout CTE_PL --entry cteModalRodoviario_v4.00.xsd --element rodo --out priv/layouts/cte_modal_rodoviario_4.00.etf
      mix sefaz.gen_layout CTE_PL --entry cteModalRodoviarioOS_v4.00.xsd --element rodoOS --out priv/layouts/cte_os_modal_rodoviario_4.00.etf
      mix sefaz.gen_layout MDFE_PL --entry mdfe_v3.00.xsd --root TMDFe --out priv/layouts/mdfe_3.00.etf
      mix sefaz.gen_layout MDFE_PL --entry mdfeModalRodoviario_v3.00.xsd --element rodo --out priv/layouts/mdfe_modal_rodoviario_3.00.etf

  The committed NF-e layout comes from `PL_010h_v1.03` (official portal, published
  13/11/2026; NT 2026.005 v1.00, NT 2026.006 v1.00, NT 2026.008 v1.01):

      mix sefaz.gen_layout /path/to/PL_010h_v1.03/NFe

  Their regeneration tests are skipped unless `SEFAZ_NFE_CTE_PL_PATH` /
  `SEFAZ_NFE_MDFE_PL_PATH` point at the unpacked PL.

  The output is `:erlang.term_to_binary/2` with `:deterministic`, so running it
  twice on the same package yields the same bytes. It records the PL name, the
  SHA-256 of every XSD it read and the generator version, so a layout can be
  traced to the exact package it came from. See `SefazNfe.Layout` for the node
  model and `SefazNfe.Layout.Generator` for how each XSD idiom is handled. An
  idiom the generator does not know makes it raise rather than drop it.

  The XSDs are never vendored (AD-015): only the generated tree is committed.

  ## Refresh procedure

  1. Download the new Pacote de Liberacao from
     https://www.nfe.fazenda.gov.br/portal/listaConteudo.aspx?tipoConteudo=BMPFMBoln3w=
     (Schemas XML) and unpack it somewhere outside this repository.
  2. Run `mix sefaz.gen_layout /path/to/PL_0XXy_vN.NN/NFe`. A new construct raises;
     extend `SefazNfe.Layout.Generator` (and its moduledoc) before going on.
  3. Run `mix test`. The layout tests assert the order of `infNFe`, the ICMS
     choice, facets and attributes; when a Nota Tecnica legitimately changes
     one of them, update the assertion in the same commit and say so.
  4. Commit `priv/layouts/nfe_4.00.etf`. The diff is binary: compare the old
     and new trees by loading both with `SefazNfe.Layout` or
     `:erlang.binary_to_term/1`; `sources` lists the hash of every XSD read.

  The test that regenerates the layout compares it to the committed file and is
  skipped when `SEFAZ_NFE_PL_PATH` does not point at a PL directory.
  """

  use Mix.Task

  alias SefazNfe.Layout.Generator

  @default_out "priv/layouts/nfe_4.00.etf"

  @impl Mix.Task
  def run(argv) do
    {opts, args} =
      OptionParser.parse!(argv,
        strict: [root: :string, out: :string, entry: :string, element: :string]
      )

    case args do
      [path] ->
        generate(path, opts)

      _ ->
        Mix.raise(
          "usage: mix sefaz.gen_layout PATH [--root TNFe] [--element NAME] [--entry FILE] [--out FILE]"
        )
    end
  end

  defp generate(path, opts) do
    unless File.dir?(path), do: Mix.raise("#{path} is not a directory")

    out = Keyword.get(opts, :out, @default_out)
    layout = Generator.generate(path, Keyword.take(opts, [:root, :entry, :element]))
    binary = Generator.encode(layout)

    out |> Path.dirname() |> File.mkdir_p!()
    File.write!(out, binary)

    Mix.shell().info(
      "#{out}: #{byte_size(binary)} bytes from #{layout.pl} " <>
        "(#{length(layout.sources)} XSDs, generator #{layout.generator})"
    )
  end
end
