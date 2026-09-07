defmodule SefazNfe.MixProject do
  use Mix.Project

  @version "0.1.0"
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
        "SEFAZ NF-e transport for Elixir: A1 certificates, mTLS, XMLDSig, " <>
          "webservices 4.00 and DistDFe. Does not calculate taxes.",
      package: [
        licenses: ["Apache-2.0"],
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
