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
      ],
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssl, :runtime_tools],
      mod: {SefazNfe.Application, []}
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.3"}
    ]
  end

  defp aliases do
    [
      precommit: ["format --check-formatted", "test"]
    ]
  end
end
