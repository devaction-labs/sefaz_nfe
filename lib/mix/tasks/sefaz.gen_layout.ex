defmodule Mix.Tasks.Sefaz.GenLayout do
  @shortdoc "Generates priv/layouts/nfe_4.00.etf from an official PL (XSD package)"

  @moduledoc """
  Compiles the NF-e `TNFe` type of an official Pacote de Liberacao into the
  ordered layout tree the builder walks (AD-024).

      mix sefaz.gen_layout PATH
      mix sefaz.gen_layout PATH --root TNFe --out priv/layouts/nfe_4.00.etf
      mix sefaz.gen_layout PATH --entry nfe_v4.00.xsd

  `PATH` is the directory of the PL (for example `PL_010_V1.30`). The task
  follows `xs:include` / `xs:import` from `--entry` (default
  `nfe_v4.00.xsd`), compiles the complex type `--root` (default `TNFe`) and
  writes `--out` (default `priv/layouts/nfe_4.00.etf`).

  The output is `:erlang.term_to_binary/2` with `:deterministic`, so running it
  twice on the same package yields the same bytes. It records the PL name, the
  SHA-256 of every XSD it read and the generator version, so a layout can be
  traced to the exact package it came from. See `SefazNfe.Layout` for the node
  model and `SefazNfe.Layout.Generator` for how each XSD idiom is handled. An
  idiom the generator does not know makes it raise rather than drop it.

  The XSDs are never vendored (AD-015): only the generated tree is committed.

  ## Refresh procedure

  1. Download the new Pacote de Liberacao from
     https://www.nfe.fazenda.gov.br/portal/principal.aspx (Schemas XML) and
     unpack it somewhere outside this repository.
  2. Run `mix sefaz.gen_layout /path/to/PL_0XX_VY.ZZ`. A new construct raises;
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
      OptionParser.parse!(argv, strict: [root: :string, out: :string, entry: :string])

    case args do
      [path] -> generate(path, opts)
      _ -> Mix.raise("usage: mix sefaz.gen_layout PATH [--root TNFe] [--entry FILE] [--out FILE]")
    end
  end

  defp generate(path, opts) do
    unless File.dir?(path), do: Mix.raise("#{path} is not a directory")

    out = Keyword.get(opts, :out, @default_out)
    layout = Generator.generate(path, Keyword.take(opts, [:root, :entry]))
    binary = Generator.encode(layout)

    out |> Path.dirname() |> File.mkdir_p!()
    File.write!(out, binary)

    Mix.shell().info(
      "#{out}: #{byte_size(binary)} bytes from #{layout.pl} " <>
        "(#{length(layout.sources)} XSDs, generator #{layout.generator})"
    )
  end
end
