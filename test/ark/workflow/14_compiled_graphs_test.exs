defmodule Ark.Workflow.CompiledGraphsTest.CompiledTuples do
  alias Ark.Workflow

  @graph Workflow.new()
         |> Workflow.add_rule(:base, %{
           alts: [default: %{deps: [], body: {__MODULE__, :base, [10]}}],
           dump: {__MODULE__, :dump, []},
           load: {__MODULE__, :load, []}
         })
         |> Workflow.add_rule(:total, %{
           alts: [
             default: %{
               deps: [:base, {__MODULE__, :deps_of, [:base]}],
               body: {__MODULE__, :total, []}
             }
           ]
         })

  def graph do
    @graph
  end

  def base(_params, _deps, _ctx, n) do
    {:ok, n}
  end

  def deps_of(_params, deps, _ctx, name) do
    %{double: {:double, %{n: deps[name]}}}
  end

  def total(_params, deps, _ctx) do
    {:ok, deps.base + deps.double}
  end

  def dump(value) do
    value
  end

  def load(data) do
    data
  end
end

defmodule Ark.Workflow.CompiledGraphsTest.CompiledCaptures do
  alias Ark.Workflow

  @graph Workflow.new()
         |> Workflow.add_rule(:base, %{
           alts: [default: %{deps: [], body: &__MODULE__.base/3}],
           dump: &__MODULE__.dump/1,
           load: &__MODULE__.load/1
         })
         |> Workflow.add_rule(:total, %{
           alts: [
             default: %{deps: [:base, &__MODULE__.deps_of/3], body: &__MODULE__.total/3}
           ]
         })

  def graph do
    @graph
  end

  def base(_params, _deps, _ctx) do
    {:ok, 10}
  end

  def deps_of(_params, deps, _ctx) do
    %{double: {:double, %{n: deps.base}}}
  end

  def total(_params, deps, _ctx) do
    {:ok, deps.base + deps.double}
  end

  def dump(value) do
    value
  end

  def load(data) do
    data
  end
end

defmodule Ark.Workflow.CompiledGraphsTest do
  use ExUnit.Case, async: true

  import Ark.Test.WorkflowHelpers

  alias Ark.Workflow
  alias Ark.Workflow.CompiledGraphsTest.CompiledCaptures
  alias Ark.Workflow.CompiledGraphsTest.CompiledTuples

  defp double_rule(wf) do
    Workflow.add_rule(wf, :double, rule([], fn %{n: n}, _, _ -> {:ok, n * 2} end))
  end

  describe "a graph whose user code is given as" do
    test "{module, function, extra_args} tuples can be built at compile time and runs" do
      graph = double_rule(CompiledTuples.graph())
      wf = run!(graph, [:total])
      assert 30 == fetch!(wf, :total)

      wf = roundtrip(wf, graph)
      assert 10 == fetch!(wf, :base)
      assert 30 == fetch!(wf, :total)
    end

    test "remote captures can be built at compile time and runs" do
      graph = double_rule(CompiledCaptures.graph())
      wf = run!(graph, [:total])
      assert 30 == fetch!(wf, :total)

      wf = roundtrip(wf, graph)
      assert 10 == fetch!(wf, :base)
      assert 30 == fetch!(wf, :total)
    end

    test "tuples or captures, built at runtime, runs like the compiled graph" do
      runtime =
        Workflow.new()
        |> Workflow.add_rule(:base, %{
          alts: [default: %{deps: [], body: &CompiledCaptures.base/3}],
          dump: &CompiledCaptures.dump/1,
          load: &CompiledCaptures.load/1
        })
        |> Workflow.add_rule(:total, %{
          alts: [
            default: %{
              deps: [:base, {CompiledTuples, :deps_of, [:base]}],
              body: {CompiledTuples, :total, []}
            }
          ]
        })
        |> double_rule()

      runtime = run!(runtime, [:total])
      compiled = CompiledTuples.graph() |> double_rule() |> run!([:total])

      for key <- [:base, :total, {:double, %{n: 10}}] do
        assert fetch!(compiled, key) == fetch!(runtime, key)
      end
    end
  end
end
