defmodule SefazNfe.MixProject do
  use Mix.Project

  def project do
    [
      app: :sefaz_nfe,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "SEFAZ NF-e transport for Elixir (sign, authorize, DistDFe). No tax calculation.",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/devaction-labs/sefaz_nfe"}
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssl]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
