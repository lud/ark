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
    test "a dependency is demanded only once every dependency to its left is ok" do
      log = start_log()

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, tracked_rule(log, :a))
        |> Workflow.add_rule(:b, rule([:b_dep], tracked(log, :b, {:ok, :b})))
        |> Workflow.add_rule(:b_dep, tracked_rule(log, :b_dep))
        |> Workflow.add_rule(:c, tracked_rule(log, :c))
        |> Workflow.add_rule(
          :r,
          rule([:a, :b, fn _, _, _ -> :c end], tracked(log, :r, {:ok, 1}))
        )

      _ = run!(wf, [:r])

      assert [:a, :b_dep, :b, :c, :r] == logged(log)
    end

    test "the first failed dependency fails the alternative with {:dep_failed, dep_key}, without calling the body nor demanding the dependencies to its right" do
      {body_pid, body} = mock_fun(0, ok_body(1))
      {c_pid, c_body} = mock_fun(0, ok_body(1))
      {deps_pid, deps_fun} = mock_fun(0, fn _, _, _ -> :c end)

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, const_rule(:a))
        |> Workflow.add_rule(:fail, failing_rule())
        |> Workflow.add_rule(:c, rule([], c_body))
        |> Workflow.add_rule(:r, rule([:a, {:fail, %{id: 1}}, :c, deps_fun], body))

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
      {a1_pid, a1_body} = mock_fun(0, ok_body(:a1))
      {b_pid, b_body} = mock_fun(1, error_body())

      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, rule([], b_body))
        |> Workflow.add_rule(:a, %{
          alts: [
            a1: %{deps: [:b], body: a1_body},
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
      {deps_pid, deps_fun} = mock_fun(0, fn _, _, _ -> :b end)
      {body_pid, body} = mock_fun(0, ok_body(:two))
      {b_pid, b_body} = mock_fun(0, ok_body(:b))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, rule([], b_body))
        |> Workflow.add_rule(:r, %{
          alts: [
            one: %{deps: [], body: ok_body(:one)},
            two: %{deps: [:b, deps_fun], body: body}
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

  test "{:dep_failed, dep_key} records the real key, never the alias it was demanded under" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:b, failing_rule())
      |> Workflow.add_rule(:r, %{
        alts: [
          static: %{deps: [%{x: {:b, %{id: 1}}}], body: ok_body(1)},
          dynamic: %{deps: [fn _, _, _ -> %{y: {:b, %{id: 2}}} end], body: ok_body(1)}
        ]
      })

    assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:r])

    assert {:ok,
            %{
              static: {:dep_failed, {:default, :b, %{id: 1}}},
              dynamic: {:dep_failed, {:default, :b, %{id: 2}}}
            }} == Workflow.attempts(wf, :r)
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
    {pid, body} = mock_fun(0, ok_body(1))

    wf =
      Workflow.new()
      |> Workflow.add_rule(:unrelated, rule([], body))
      |> Workflow.add_rule(:unrelated_dep, rule([], body))
      |> Workflow.add_rule(:unrelated_consumer, rule([:a, :unrelated_dep], body))
      |> Workflow.add_rule(:a, const_rule(1))
      |> Workflow.add_rule(:r, %{
        alts: [
          one: %{deps: [:a], body: ok_body(1)},
          two: %{deps: [:unrelated], body: body}
        ]
      })

    wf = run!(wf, [:r])

    verify(pid)

    for key <- [:unrelated, :unrelated_dep, :unrelated_consumer] do
      assert :error == Workflow.fetch(wf, key)
    end
  end

  test "a key demanded by several consumers in one run is computed once" do
    {pid, body} = mock_fun(1, ok_body(:shared))

    wf =
      Workflow.new()
      |> Workflow.add_rule(:shared, rule([], body))
      |> Workflow.add_rule(:left, rule([:shared], deps_body()))
      |> Workflow.add_rule(:right, rule([fn _, _, _ -> :shared end], deps_body()))
      |> Workflow.add_rule(:top, rule([:left, :right, :shared], deps_body()))

    wf = run!(wf, [:top, :shared])

    verify(pid)

    assert %{left: %{shared: :shared}, right: %{shared: :shared}, shared: :shared} ==
             fetch!(wf, :top)
  end

  describe "the same real key demanded under different aliases is computed once and recorded under its real identity" do
    setup do
      {pid, body} = mock_fun(1, ok_body(:va))
      wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))
      %{pid: pid, wf: wf}
    end

    test "from two consumers", %{pid: pid, wf: wf} do
      wf =
        wf
        |> Workflow.add_rule(:r1, rule([%{"foo_123" => :a}], deps_body()))
        |> Workflow.add_rule(
          :r2,
          rule([fn _, _, _ -> %{"foo_test" => {:a, %{}}} end], deps_body())
        )

      wf = run!(wf, [:r1, :r2])

      verify(pid)
      assert %{"foo_123" => :va} == fetch!(wf, :r1)
      assert %{"foo_test" => :va} == fetch!(wf, :r2)
      assert :va == fetch!(wf, :a)
    end

    test "from two dependency functions of one alternative", %{pid: pid, wf: wf} do
      wf =
        Workflow.add_rule(
          wf,
          :r,
          rule(
            [fn _, _, _ -> %{x: :a} end, fn _, _, _ -> %{y: {:default, :a, %{}}} end],
            deps_body()
          )
        )

      wf = run!(wf, [:r])

      verify(pid)
      assert %{x: :va, y: :va} == fetch!(wf, :r)
      assert :va == fetch!(wf, :a)
    end

    test "from one dependency function returning both aliases", %{pid: pid, wf: wf} do
      wf =
        Workflow.add_rule(
          wf,
          :r,
          rule([fn _, _, _ -> %{x: :a, y: {:a, %{}}} end], deps_body())
        )

      wf = run!(wf, [:r])

      verify(pid)
      assert %{x: :va, y: :va} == fetch!(wf, :r)
      assert :va == fetch!(wf, :a)
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
      {pid, body} = mock_fun(0, ok_body(1))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, const_rule(:a))
        |> Workflow.add_rule(:fail, rule([:fail_dep], ok_body(1)))
        |> Workflow.add_rule(:fail_dep, failing_rule())
        |> Workflow.add_rule(:later, rule([], body))

      assert {:error, %ComputationError{target: {:default, :fail, %{}}}, wf} =
               Workflow.run(wf, [:a, :fail, :later])

      verify(pid)
      assert {:ok, :a} == Workflow.fetch(wf, :a)
      assert :error == Workflow.fetch(wf, :later)
    end
  end
end
