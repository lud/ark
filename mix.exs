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
      deps: deps(),
      # consolidate_protocols: Mix.env() != :test,
      description: @description,
      package: package(),
      source_url: "https://github.com/lud/ark",
      docs: [main: "Ark"]
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

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false}
    ]
  end
end
