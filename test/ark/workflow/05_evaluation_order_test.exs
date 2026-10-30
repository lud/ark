defmodule Ark.Workflow.EvaluationOrderTest do
  use ExUnit.Case, async: true

  import Ark.Test.Mock
  import Ark.Test.WorkflowHelpers

  alias Ark.Workflow
  alias Ark.Workflow.ComputationError

  defp tracked(log, name, result) do
    fn _, _, _ ->
      track(log, name)
      result
    end
  end

  defp tracked_rule(log, name, result \\ nil) do
    rule([], tracked(log, name, result || {:ok, name}))
  end

  describe "within an alternative, dependencies are resolved left to right" do
    test "the first failed dependency fails the alternative with {:dep_failed, dep_key}, without calling the body nor demanding the dependencies to its right" do
      {body_pid, never_body} = mock_never(ok_body(1))
      {c_pid, never_c} = mock_never(ok_body(1))
      {deps_pid, never_deps} = mock_never(fn _, _, _ -> :c end)

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, const_rule(:a))
        |> Workflow.add_rule(:fail, failing_rule())
        |> Workflow.add_rule(:c, rule([], never_c))
        |> Workflow.add_rule(
          :r,
          rule([:a, {:fail, %{id: 1}}, :c, never_deps], never_body)
        )

      assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:r])

      verify(body_pid)
      verify(c_pid)
      verify(deps_pid)

      assert {:ok, %{default: {:dep_failed, {:default, :fail, %{id: 1}}}}} ==
               Workflow.attempts(wf, :r)

      assert :error == Workflow.fetch(wf, :c)
    end
  end

  describe "alternatives are tried in order" do
    test "the next alternative is entered only after the previous one failed" do
      log = start_log()

      wf =
        Workflow.add_rule(Workflow.new(), :r, %{
          alts: [
            one: %{deps: [], body: tracked(log, :one, {:error, :x})},
            two: %{deps: [], body: tracked(log, :two, :bad_return)},
            three: %{deps: [], body: tracked(log, :three, {:ok, :three})}
          ]
        })

      wf = run!(wf, [:r])

      assert [:one, :two, :three] == logged(log)
      assert :three == fetch!(wf, :r)
    end

    test "the dependencies of the next alternative are not demanded before the previous one failed" do
      log = start_log()

      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, tracked_rule(log, :b))
        |> Workflow.add_rule(:c, tracked_rule(log, :c))
        |> Workflow.add_rule(:a, %{
          alts: [
            a1: %{deps: [:b], body: tracked(log, :a1, {:error, :x})},
            a2: %{deps: [:c], body: tracked(log, :a2, {:ok, :a2})}
          ]
        })

      wf = run!(wf, [:a])

      assert [:b, :a1, :c, :a2] == logged(log)
      assert :a2 == fetch!(wf, :a)
    end

    test "an alternative whose dependency is already failed fails without calling its body, and the next alternative is entered" do
      {a1_pid, never} = mock_never(ok_body(:a1))
      {b_pid, b_body} = mock_fun(1, error_body())

      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, rule([], b_body))
        |> Workflow.add_rule(:a, %{
          alts: [
            a1: %{deps: [:b], body: never},
            a2: %{deps: [], body: ok_body(:a2)}
          ]
        })

      assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:b])
      wf = run!(wf, [:a])

      verify(a1_pid)
      verify(b_pid)
      assert :a2 == fetch!(wf, :a)
      assert {:ok, %{a1: {:dep_failed, {:default, :b, %{}}}}} == Workflow.attempts(wf, :a)
    end

    test "no alternative is entered once one succeeded" do
      {deps_pid, never_deps} = mock_never(fn _, _, _ -> :b end)
      {body_pid, never_body} = mock_never(ok_body(:two))
      {b_pid, never_b} = mock_never(ok_body(:b))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, rule([], never_b))
        |> Workflow.add_rule(:r, %{
          alts: [
            one: %{deps: [], body: ok_body(:one)},
            two: %{deps: [:b, never_deps], body: never_body}
          ]
        })

      wf = run!(wf, [:r])

      verify(deps_pid)
      verify(body_pid)
      verify(b_pid)
      assert :one == fetch!(wf, :r)
      assert {:ok, %{}} == Workflow.attempts(wf, :r)
    end
  end

  test "a key whose alternatives all failed is failed with {:all_alternatives_failed, alt_names}, listing every attempted alternative" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:b, failing_rule())
      |> Workflow.add_rule(:r, %{
        alts: [
          zed: %{deps: [], body: error_body()},
          alpha: %{deps: [:b], body: ok_body(1)},
          mid: %{deps: [], body: fn _, _, _ -> raise "x" end}
        ]
      })

    assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:r])

    assert {:failed, {:all_alternatives_failed, [:zed, :alpha, :mid]}} ==
             Workflow.fetch(wf, :r)

    assert {:ok,
            %{
              zed: {:computation_error, %{kind: :user_term}},
              alpha: {:dep_failed, {:default, :b, %{}}},
              mid: {:computation_error, %{kind: :error}}
            }} = Workflow.attempts(wf, :r)
  end

  test "a consumer of a failed key fails with {:dep_failed, key}, transitively up to the target" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([:b], ok_body(1)))
      |> Workflow.add_rule(:b, rule([{:c, %{id: 1}}], ok_body(1)))
      |> Workflow.add_rule(:c, failing_rule())

    assert {:error, %ComputationError{target: {:default, :a, %{}}}, wf} =
             Workflow.run(wf, [:a])

    assert {:failed, {:all_alternatives_failed, [:default]}} == Workflow.fetch(wf, :a)
    assert {:failed, {:all_alternatives_failed, [:default]}} == Workflow.fetch(wf, :b)

    assert {:failed, {:all_alternatives_failed, [:default]}} ==
             Workflow.fetch(wf, {:c, %{id: 1}})

    assert {:ok, %{default: {:dep_failed, {:default, :b, %{}}}}} ==
             Workflow.attempts(wf, :a)

    assert {:ok, %{default: {:dep_failed, {:default, :c, %{id: 1}}}}} ==
             Workflow.attempts(wf, :b)

    assert {:ok, %{default: {:computation_error, _}}} =
             Workflow.attempts(wf, {:c, %{id: 1}})
  end

  test "a key failed earlier in a run is not computed again when another consumer demands it in the same run" do
    {pid, body} = mock_fun(1, error_body())

    consumer = %{
      alts: [
        one: %{deps: [:f], body: ok_body(:one)},
        two: %{deps: [], body: ok_body(:two)}
      ]
    }

    wf =
      Workflow.new()
      |> Workflow.add_rule(:f, rule([], body))
      |> Workflow.add_rule(:x, consumer)
      |> Workflow.add_rule(:y, consumer)
      |> Workflow.add_rule(:z, consumer)

    wf = run!(wf, [:x, :y, :z])

    verify(pid)
    assert :two == fetch!(wf, :y)
  end

  test "nothing is computed unless it is a target or transitively demanded by one" do
    {pid, never} = mock_never(ok_body(1))

    wf =
      Workflow.new()
      |> Workflow.add_rule(:unrelated, rule([], never))
      |> Workflow.add_rule(:unrelated_dep, rule([], never))
      |> Workflow.add_rule(:unrelated_consumer, rule([:a, :unrelated_dep], never))
      |> Workflow.add_rule(:a, const_rule(1))
      |> Workflow.add_rule(:r, %{
        alts: [
          one: %{deps: [:a], body: ok_body(1)},
          two: %{deps: [:unrelated], body: never}
        ]
      })

    wf = run!(wf, [:r])

    verify(pid)

    for key <- [:unrelated, :unrelated_dep, :unrelated_consumer] do
      assert :error == Workflow.fetch(wf, key)
    end
  end

  describe "targets are demanded in order" do
    test "the next target is demanded only once the previous one has a value" do
      log = start_log()

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([:a_dep], tracked(log, :a, {:ok, :a})))
        |> Workflow.add_rule(:a_dep, tracked_rule(log, :a_dep))
        |> Workflow.add_rule(:b, tracked_rule(log, :b))
        |> Workflow.add_rule(:c, tracked_rule(log, :c))

      _ = run!(wf, [:c, :a, :b])

      assert [:c, :a_dep, :a, :b] == logged(log)
    end

    test "the first failed target stops the run, later targets are never demanded" do
      {pid, never} = mock_never(ok_body(1))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, const_rule(:a))
        |> Workflow.add_rule(:fail, rule([:fail_dep], ok_body(1)))
        |> Workflow.add_rule(:fail_dep, failing_rule())
        |> Workflow.add_rule(:later, rule([], never))

      assert {:error, %ComputationError{target: {:default, :fail, %{}}}, wf} =
               Workflow.run(wf, [:a, :fail, :later])

      verify(pid)
      assert {:ok, :a} == Workflow.fetch(wf, :a)
      assert :error == Workflow.fetch(wf, :later)
    end
  end
end
