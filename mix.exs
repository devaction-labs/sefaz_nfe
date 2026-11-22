defmodule SefazNfe.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/devaction-labs/sefaz_nfe"

  def project do
    [
      app: :sefaz_nfe,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      name: "sefaz_nfe",
      source_url: @source_url,
      description:
        "SEFAZ transport for Elixir: NF-e (55), NFC-e (65), CT-e (57/67) and MDF-e (58), " <>
          "with builder and parser, A1 certificates, mTLS, XMLDSig, webservices, " <>
          "DistDFe, contingency and telemetry. Does not calculate taxes.",
      package: [
        licenses: ["Apache-2.0"],
        files: ~w(lib priv/endpoints priv/layouts mix.exs README.md CHANGELOG.md LICENSE),
        links: %{"GitHub" => @source_url, "Changelog" => @source_url <> "/blob/main/CHANGELOG.md"}
      ],
      dialyzer: [plt_add_apps: [:mix]],
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md", "LICENSE"],
        source_ref: "v#{@version}"
      ],
      aliases: aliases()
    ]
  end

  # `mix test` inside an alias would otherwise run in :dev and abort.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssl, :inets, :xmerl, :runtime_tools],
      mod: {SefazNfe.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.3"},
      {:decimal, "~> 2.0", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test"
      ]
    ]
  end
end
