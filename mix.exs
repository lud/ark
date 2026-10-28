defmodule Ark.MixProject do
  use Mix.Project

  @description """
  Ark is a collection of small utilities useful for prototyping,
  testing, and working with Elixir common patterns.
  """

  def project do
    [
      app: :ark,
      version: "0.14.0",
      elixir: "~> 1.9",
      start_permanent: false,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      # consolidate_protocols: Mix.env() != :test,
      description: @description,
      package: package(),
      source_url: "https://github.com/lud/ark",
      dialyzer: dialyzer(),
      versioning: versioning(),
      docs: [
        main: "readme",
        extras: ["README.md"]
      ]
    ]
  end

  defp elixirc_paths(:prod) do
    ["lib"]
  end

  defp elixirc_paths(:test) do
    ["lib", "dev", "test/support"]
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
      _ -> [extra_applications: [:logger]]
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
      plt_add_apps: [:readmix, :ecto, :ex_unit],
      plt_local_path: "_build/plts"
    ]
  end

  defp deps do
    [
      # Lib
      {:ecto, "~> 3.10", optional: true},
      {:telemetry, "~> 1.0", optional: true},

      # Dev & Test
      {:ecto_sqlite3, "~> 0.26.0", only: :test},
      {:postgrex, "~> 0.22.4", only: :test},
      {:readmix, "~> 0.7", only: [:dev, :test], runtime: false},
      {:libdev, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp versioning do
    [
      before_commit: [
        &readmix/1,
        {:add, "README.md"},
        &gen_changelog/2,
        {:add, "CHANGELOG.md"}
      ]
    ]
  end

  def readmix(vsn) do
    rdmx = Readmix.new(vars: %{app_vsn: vsn})
    :ok = Readmix.update_file(rdmx, "README.md")
  end

  defp gen_changelog(vsn, info) do
    args = [
      "cliff",
      "--tag",
      vsn,
      "--with-tag-message",
      info.annotation,
      "-o",
      "CHANGELOG.md"
    ]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_, 0} -> IO.puts("Updated CHANGELOG.md with #{vsn}")
      {out, _} -> {:error, "Could not update CHANGELOG.md:\n\n #{out}"}
    end
  end
end
