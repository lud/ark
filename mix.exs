defmodule Ark.MixProject do
  use Mix.Project

  @description """
  Ark is a collection of small utilities useful for prototyping,
  testing, and working with Elixir common patterns.
  """

  def project do
    [
      app: :ark,
      version: "0.9.0",
      elixir: "~> 1.9",
      start_permanent: false,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      # consolidate_protocols: Mix.env() != :test,
      description: @description,
      package: package(),
      source_url: "https://github.com/lud/ark",
      dialyzer: dialyzer(),
      docs: [
        main: "readme",
        extras: ["README.md"]
      ]
    ]
  end

  defp elixirc_paths(:prod) do
    ["lib"]
  end

  defp elixirc_paths(_) do
    ["lib", "dev"]
  end

  def cli do
    [
      preferred_envs: [
        dialyzer: :test
      ]
    ]
  end

  def application do
    case Mix.env() do
      :test -> [extra_applications: [:sasl, :logger]]
      _ -> []
    end
  end

  def package() do
    [
      name: "ark",
      licenses: ["MIT"],
      links: %{"Github" => "https://github.com/lud/ark"}
    ]
  end

  defp dialyzer do
    [
      flags: [:unmatched_returns, :error_handling, :unknown, :extra_return],
      list_unused_filters: true,
      plt_add_deps: :app_tree,
      plt_add_apps: [:readmix],
      plt_local_path: "_build/plts"
    ]
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:readmix, "~> 0.7", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_check, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end
end
