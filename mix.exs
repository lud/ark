defmodule Ark.MixProject do
  use Mix.Project

  @description """
  Ark is a collection of small utilities useful for prototyping, 
  testing, and working with Elixir common patterns.
  """

  def project do
    [
      app: :ark,
      version: "0.4.2",
      elixir: "~> 1.9",
      start_permanent: false,
      deps: deps(),
      description: @description,
      package: package(),
      docs: [main: "Ark"]
    ]
  end

  def application do
    case Mix.env() do
      :test -> [extra_applications: [:logger]]
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
      {:ex_doc, ">= 0.0.0", only: :dev}
    ]
  end
end
