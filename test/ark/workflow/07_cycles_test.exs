defmodule Ark.Workflow.CyclesTest do
  use ExUnit.Case, async: true

  import Ark.Test.Mock
  import Ark.Test.WorkflowHelpers

  alias Ark.Workflow
  alias Ark.Workflow.GraphError

  defmodule NsA do
  end

  defp key(name, params \\ %{}) do
    {:default, name, params}
  end

  defp assert_cycle(wf, targets) do
    assert {:error, %GraphError{kind: :cycle} = e, wf} = Workflow.run(wf, targets)
    {e, wf}
  end

  test "a dependency function returning a key in progress makes run stop with a graph error carrying the demanded key and the demand stack leading back to it, recording nothing for the keys of the cycle" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:ok, const_rule(1))
      |> Workflow.add_rule(:top, rule([:a], ok_body(1)))
      |> Workflow.add_rule(:a, rule([:ok, :b], ok_body(1)))
      |> Workflow.add_rule(:b, rule([fn _, _, _ -> :a end], ok_body(1)))

    {e, wf} = assert_cycle(wf, [:top])

    assert key(:a) == e.key
    assert [key(:top), key(:a), key(:b)] == e.stack
    assert {:ok, 1} == Workflow.fetch(wf, :ok)

    for name <- [:top, :a, :b] do
      assert :error == Workflow.fetch(wf, name)
      assert {:ok, %{}} == Workflow.attempts(wf, name)
    end
  end

  test "a static dependency chain that loops back to a key in progress makes run stop the same way" do
    {pid, body} = mock_fun(0, ok_body(1))

    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([:b], body))
      |> Workflow.add_rule(:b, rule([:c], body))
      |> Workflow.add_rule(:c, rule([:a], body))

    {e, wf} = assert_cycle(wf, [:a])

    verify(pid)
    assert key(:a) == e.key
    assert [key(:a), key(:b), key(:c)] == e.stack

    for name <- [:a, :b, :c] do
      assert :error == Workflow.fetch(wf, name)
      assert {:ok, %{}} == Workflow.attempts(wf, name)
    end
  end

  test "a key demanded twice from different branches (a diamond) is not a cycle: it is computed once" do
    {pid, body} = mock_fun(1, ok_body(:shared))

    wf =
      Workflow.new()
      |> Workflow.add_rule(:shared, rule([], body))
      |> Workflow.add_rule(:left, rule([:shared], deps_body()))
      |> Workflow.add_rule(:right, rule([fn _, _, _ -> :shared end], deps_body()))
      |> Workflow.add_rule(:top, rule([:left, :right], deps_body()))

    wf = run!(wf, [:top])

    verify(pid)
    assert %{left: %{shared: :shared}, right: %{shared: :shared}} == fetch!(wf, :top)
  end

  test "a direct self-dependency makes run stop with a graph error" do
    wf = Workflow.add_rule(Workflow.new(), :a, rule([:a], ok_body(1)))
    {e, _} = assert_cycle(wf, [:a])
    assert key(:a) == e.key
    assert [key(:a)] == e.stack

    wf =
      Workflow.add_rule(
        Workflow.new(),
        :a,
        rule([fn _, _, _ -> {:a, %{}} end], ok_body(1))
      )

    {e, _} = assert_cycle(wf, [:a])
    assert key(:a) == e.key
  end

  test "a key in progress demanded under another form is detected as a cycle" do
    wf =
      Workflow.new()
      |> Workflow.add_rule({NsA, :a}, rule([:b], ok_body(1)))
      |> Workflow.add_rule(
        {NsA, :b},
        rule([fn _, _, _ -> {NsA, :a, %{}} end], ok_body(1))
      )

    {e, _} = assert_cycle(wf, [{NsA, :a, %{}}])
    assert {NsA, :a, %{}} == e.key

    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([:b], ok_body(1)))
      |> Workflow.add_rule(:b, rule([{:default, :a, %{}}], ok_body(1)))

    {e, _} = assert_cycle(wf, [{:a, %{}}])
    assert key(:a) == e.key
  end

  test "a cycle reachable only through a later alternative makes run stop with a graph error when that alternative is entered" do
    log = start_log()

    cyclic = fn first_result ->
      Workflow.new()
      |> Workflow.add_rule(:a, %{
        alts: [
          one: %{
            deps: [],
            body: fn _, _, _ ->
              track(log, :one)
              first_result
            end
          },
          two: %{deps: [:b], body: ok_body(:two)}
        ]
      })
      |> Workflow.add_rule(:b, rule([:a], ok_body(1)))
    end

    wf = run!(cyclic.({:ok, :one}), [:a])
    assert :one == fetch!(wf, :a)

    {e, wf} = assert_cycle(cyclic.({:error, :x}), [:a])
    assert key(:a) == e.key
    assert [:one, :one] == logged(log)
    assert :error == Workflow.fetch(wf, :a)
    assert {:ok, %{one: {:computation_error, _}}} = Workflow.attempts(wf, :a)
  end

  test "a rule demanding itself with other params is not a cycle" do
    wf =
      Workflow.add_rule(Workflow.new(), :fact, %{
        alts: [
          default: %{
            deps: [
              fn
                %{n: 0}, _, _ -> []
                %{n: n}, _, _ -> %{prev: {:fact, %{n: n - 1}}}
              end
            ],
            body: fn
              %{n: 0}, _, _ -> {:ok, 1}
              %{n: n}, %{prev: prev}, _ -> {:ok, n * prev}
            end
          }
        ]
      })

    wf = run!(wf, [{:fact, %{n: 5}}])
    assert 120 == fetch!(wf, {:fact, %{n: 5}})
    assert 6 == fetch!(wf, {:fact, %{n: 3}})
  end

  test "a chain of 10,000 dependent keys computes, and the cycle check stays cheap at that depth" do
    wf =
      Workflow.add_rule(Workflow.new(), :chain, %{
        alts: [
          default: %{
            deps: [
              fn
                %{n: 0}, _, _ -> []
                %{n: n}, _, _ -> %{prev: {:chain, %{n: n - 1}}}
              end
            ],
            body: fn
              %{n: 0}, _, _ -> {:ok, 0}
              %{n: _}, %{prev: prev}, _ -> {:ok, prev + 1}
            end
          }
        ]
      })

    {micros, wf} = :timer.tc(fn -> run!(wf, [{:chain, %{n: 10_000}}]) end)

    assert 10_000 == fetch!(wf, {:chain, %{n: 10_000}})
    assert micros < 3_000_000, "10,000 keys took #{div(micros, 1000)}ms"
  end
end
