defmodule Auth2ApiEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :auth2api_ex,
      version: "1.0.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Auth2ApiEx.Application, []}
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.11"},
      {:req, "~> 0.5"},
      {:ezstd, "~> 1.2"},
      {:uuid, "~> 1.1"},
      {:websockex, "~> 0.4"},
      {:mox, "~> 1.0", only: :test}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp releases do
    [
      auth2api_ex: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
