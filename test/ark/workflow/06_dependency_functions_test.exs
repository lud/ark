defmodule Ark.Workflow.DependencyFunctionsTest do
  use ExUnit.Case, async: true

  import Ark.Test.Mock
  import Ark.Test.WorkflowHelpers

  alias Ark.Workflow
  alias Ark.Workflow.ComputationError
  alias Ark.Workflow.GraphError

  defmodule NsA do
  end

  def return_b(_params, _deps, _ctx) do
    :b
  end

  def return_key(_params, _deps, _ctx, key) do
    key
  end

  defp tracked(log, name, result) do
    fn _, _, _ ->
      track(log, name)
      result
    end
  end

  defp tracked_rule(log, name) do
    rule([], tracked(log, name, {:ok, name}))
  end

  defp base_graph do
    Workflow.new()
    |> Workflow.add_rule(:a, const_rule(:va))
    |> Workflow.add_rule(:b, const_rule(:vb))
    |> Workflow.add_rule(:c, const_rule(:vc))
    |> Workflow.add_rule(:fail, failing_rule())
  end

  defp run_graph_error(wf, targets) do
    assert {:error, %GraphError{} = e, wf} = Workflow.run(wf, targets)
    {e, wf}
  end

  defp invalid_return_error(value) do
    wf =
      Workflow.add_rule(base_graph(), :r, rule([:a, fn _, _, _ -> value end], ok_body(1)))

    {e, _} = run_graph_error(wf, [:r])
    e
  end

  describe "a dependency function" do
    test "is called only once every dependency to its left is ok" do
      log = start_log()

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, tracked_rule(log, :a))
        |> Workflow.add_rule(:b, tracked_rule(log, :b))
        |> Workflow.add_rule(:r, rule([:a, :b, tracked(log, :deps, [])], ok_body(1)))

      _ = run!(wf, [:r])

      assert [:a, :b, :deps | _] = logged(log)
    end

    test "receives the computed key's params, only the dependencies to its left, and the context" do
      {pid1, fun1} = mock_fun(100, fn _, _, _ -> %{x: :c} end)
      {pid2, fun2} = mock_fun(100, fn _, _, _ -> [] end)

      wf = Workflow.add_rule(base_graph(), :r, rule([:a, fun1, :b, fun2], ok_body(1)))
      _ = run!(wf, [{:r, %{id: 1}}], context: %{ctx: 1})

      assert [_ | _] = calls(pid1)
      assert [_ | _] = calls(pid2)
      assert [%{id: 1}, %{a: :va}, %{ctx: 1}] == List.last(calls(pid1))
      assert [%{id: 1}, %{a: :va, x: :vc, b: :vb}, %{ctx: 1}] == List.last(calls(pid2))
    end

    test "receives the dynamic dependencies to its left under their aliases" do
      {pid, fun} = mock_fun(100, fn _, _, _ -> [] end)

      wf =
        Workflow.add_rule(
          base_graph(),
          :r,
          rule(
            [fn _, _, _ -> %{"alias" => :a} end, fn _, _, _ -> [:b] end, fun],
            ok_body(1)
          )
        )

      _ = run!(wf, [:r])

      assert [%{}, %{"alias" => :va, b: :vb}, %{}] == List.last(calls(pid))
    end

    test "is not called when a dependency to its left is failed" do
      {pid, fun} = mock_fun(0, fn _, _, _ -> :a end)
      wf = Workflow.add_rule(base_graph(), :r, rule([:a, :fail, fun], ok_body(1)))

      assert {:error, %ComputationError{}, _} = Workflow.run(wf, [:r])
      verify(pid)
    end

    test "is not called once the key has a value, in the same run" do
      {pid, fun} = mock_fun(100, fn _, _, _ -> :a end)

      wf =
        base_graph()
        |> Workflow.add_rule(:r, rule([fun], deps_body()))
        |> Workflow.add_rule(:consumer, rule([:r], deps_body()))

      wf = run!(wf, [:r])
      count = length(calls(pid))
      assert count > 0

      wf = run!(wf, [:consumer, :r])
      assert %{r: %{a: :va}} == fetch!(wf, :consumer)
      assert count == length(calls(pid))
    end
  end

  describe "the keys a dependency function returns" do
    test "are demanded before the entries to its right" do
      log = start_log()

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, tracked_rule(log, :a))
        |> Workflow.add_rule(:b, tracked_rule(log, :b))
        |> Workflow.add_rule(:c, tracked_rule(log, :c))
        |> Workflow.add_rule(:r, rule([fn _, _, _ -> [:b, :a] end, :c], ok_body(1)))

      _ = run!(wf, [:r])

      assert [:b, :a, :c] == logged(log)
    end

    test "as an alias map are exposed in deps under their aliases" do
      wf =
        base_graph()
        |> Workflow.add_rule({NsA, :n}, const_rule(:vn))
        |> Workflow.add_rule(
          :r,
          rule([fn _, _, _ -> %{x: :a, y: {:b, %{}}, z: {NsA, :n, %{}}} end], deps_body())
        )

      wf = run!(wf, [:r])
      assert %{x: :va, y: :vb, z: :vn} == fetch!(wf, :r)
    end

    test "as a list are exposed under their shortest forms" do
      wf =
        base_graph()
        |> Workflow.add_rule({NsA, :n}, rule([], params_body()))
        |> Workflow.add_rule(
          :r,
          rule(
            [fn _, _, _ -> [:a, {:b, %{}}, {:default, :c, %{}}, {NsA, :n, %{id: 1}}] end],
            deps_body()
          )
        )

      wf = run!(wf, [:r])

      assert %{:a => :va, :b => :vb, :c => :vc, {NsA, :n, %{id: 1}} => %{id: 1}} ==
               fetch!(wf, :r)
    end

    test "as a single key are exposed under its shortest form" do
      wf =
        base_graph()
        |> Workflow.add_rule(:p, rule([], params_body()))
        |> Workflow.add_rule(
          :r1,
          rule([fn _, _, _ -> {:default, :a, %{}} end], deps_body())
        )
        |> Workflow.add_rule(:r2, rule([fn _, _, _ -> {:p, %{id: 1}} end], deps_body()))

      wf = run!(wf, [:r1, :r2])

      assert %{a: :va} == fetch!(wf, :r1)
      assert %{{:p, %{id: 1}} => %{id: 1}} == fetch!(wf, :r2)
    end

    test "as a list are demanded in list order: the first failed key fails the alternative, and the keys after it are not demanded" do
      log = start_log()

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, tracked_rule(log, :a))
        |> Workflow.add_rule(:fail, rule([], tracked(log, :fail, {:error, :x})))
        |> Workflow.add_rule(:c, tracked_rule(log, :c))
        |> Workflow.add_rule(:r, rule([fn _, _, _ -> [:a, :fail, :c] end], ok_body(1)))

      assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:r])

      assert [:a, :fail] == logged(log)

      assert {:ok, %{default: {:dep_failed, {:default, :fail, %{}}}}} ==
               Workflow.attempts(wf, :r)
    end

    test "as an alias map are demanded in ordered-iterator order, with the same short-circuit" do
      log = start_log()

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, tracked_rule(log, :a))
        |> Workflow.add_rule(:fail, rule([], tracked(log, :fail, {:error, :x})))
        |> Workflow.add_rule(:c, tracked_rule(log, :c))
        |> Workflow.add_rule(
          :r,
          rule([fn _, _, _ -> %{3 => :c, 1 => :a, 2 => :fail} end], ok_body(1))
        )

      assert {:error, %ComputationError{}, _} = Workflow.run(wf, [:r])

      assert [:a, :fail] == logged(log)
    end

    test "as a large alias map are demanded in ordered-iterator order" do
      log = start_log()
      aliases = Enum.map(60..1//-1, &:"alias_#{&1}")

      wf =
        Workflow.new()
        |> Workflow.add_rule(:leaf, rule([], fn p, _, _ -> track(log, p) && {:ok, 1} end))
        |> Workflow.add_rule(
          :r,
          rule(
            [fn _, _, _ -> Map.new(aliases, &{&1, {:leaf, %{alias: &1}}}) end],
            ok_body(1)
          )
        )

      _ = run!(wf, [:r])

      assert Enum.map(Enum.sort(aliases), &%{alias: &1}) == logged(log)
    end

    test "written name or {name, params} resolve in the namespace of the demanding rule, also when a {module, function, extra_args} dependency function is defined in another module" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, const_rule(:default_b))
        |> Workflow.add_rule({NsA, :b}, rule([], params_body()))
        |> Workflow.add_rule(
          {NsA, :r},
          rule(
            [
              {__MODULE__, :return_key, [%{x: :b}]},
              &__MODULE__.return_b/3,
              {__MODULE__, :return_key, [{:b, %{id: 1}}]}
            ],
            deps_body()
          )
        )

      wf = run!(wf, [{NsA, :r, %{}}])

      assert %{:x => %{}, :b => %{}, {:b, %{id: 1}} => %{id: 1}} ==
               fetch!(wf, {NsA, :r, %{}})
    end
  end

  test "a dependency function returning an empty map or an empty list demands nothing, and the body runs" do
    {pid, body} = mock_fun(2, deps_body())

    wf =
      base_graph()
      |> Workflow.add_rule(:r1, rule([fn _, _, _ -> %{} end], body))
      |> Workflow.add_rule(:r2, rule([:a, fn _, _, _ -> [] end], body))

    wf = run!(wf, [:r1, :r2])

    verify(pid)
    assert %{} == fetch!(wf, :r1)
    assert %{a: :va} == fetch!(wf, :r2)
  end

  test "when a dependency function returns different keys across calls, the engine follows the keys of the latest call; values of keys no longer returned stay recorded" do
    phase = start_log()

    deps_fun = fn _, _, _ ->
      case logged(phase) do
        [] -> [:b, :broken]
        _ -> [:c]
      end
    end

    wf =
      base_graph()
      |> Workflow.add_rule(:broken, rule([fn _, _, _ -> "not a key" end], ok_body(1)))
      |> Workflow.add_rule(:r, rule([deps_fun], deps_body()))

    {_, wf} = run_graph_error(wf, [:r])
    assert {:ok, :vb} == Workflow.fetch(wf, :b)

    track(phase, :second)
    wf = run!(wf, [:r])

    assert %{c: :vc} == fetch!(wf, :r)
    assert {:ok, :vb} == Workflow.fetch(wf, :b)
  end

  describe "a dependency function that" do
    defp failing_deps_attempt(deps_fun) do
      {pid, body} = mock_fun(0, ok_body(1))

      wf =
        Workflow.add_rule(base_graph(), :r, %{
          alts: [
            first: %{deps: [:a, deps_fun], body: body},
            second: %{deps: [], body: ok_body(:second)}
          ]
        })

      wf = run!(wf, [:r])

      verify(pid)
      assert :second == fetch!(wf, :r)
      assert {:ok, %{first: {:computation_error, cleaned}}} = Workflow.attempts(wf, :r)
      cleaned
    end

    test "raises fails the alternative with a :computation_error, and the next alternative is entered" do
      assert %{kind: :error, message: error} =
               failing_deps_attempt(fn _, _, _ -> raise "boom" end)

      assert error =~ "boom"
    end

    test "throws fails the alternative with kind :throw" do
      assert %{kind: :throw} = failing_deps_attempt(fn _, _, _ -> throw(:x) end)
    end

    test "exits fails the alternative with kind :exit" do
      assert %{kind: :exit} = failing_deps_attempt(fn _, _, _ -> exit(:x) end)
    end
  end

  describe "a dependency function returning an invalid dependency makes run stop with a graph error" do
    setup do
      {a_pid, a_body} = mock_fun(1, ok_body(:va))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([], a_body))
        |> Workflow.add_rule(:r, %{
          alts: [
            first: %{deps: [], body: error_body()},
            second: %{deps: [:a, fn _, _, _ -> "invalid" end], body: ok_body(1)}
          ]
        })
        |> Workflow.add_rule(:top, rule([{:r, %{id: 1}}], ok_body(1)))

      %{wf: wf, a_pid: a_pid}
    end

    test "carrying the returned value, and the key and alternative whose dependency function returned it",
         %{wf: wf} do
      {e, _} = run_graph_error(wf, [:top])

      assert "invalid" == e.value
      assert {:default, :r, %{id: 1}} == e.key
      assert :second == e.alternative
    end

    test "returned with the workflow and every fact recorded before", %{
      wf: wf,
      a_pid: a_pid
    } do
      {_, wf} = run_graph_error(wf, [:top])

      verify(a_pid)
      assert {:ok, :va} == Workflow.fetch(wf, :a)

      assert {:ok, %{first: {:computation_error, _}}} =
               Workflow.attempts(wf, {:r, %{id: 1}})
    end

    test "recording nothing for the key whose dependency function returned it", %{wf: wf} do
      {_, wf} = run_graph_error(wf, [:top])

      assert :error == Workflow.fetch(wf, {:r, %{id: 1}})
      assert {:ok, attempts} = Workflow.attempts(wf, {:r, %{id: 1}})
      refute Map.has_key?(attempts, :second)
      assert :error == Workflow.fetch(wf, :top)
      assert {:ok, %{}} == Workflow.attempts(wf, :top)
    end
  end

  describe "invalid dependencies, each a graph error" do
    test "nil, true and false, reported as invalid returns, not as keys with no rule" do
      for value <- [nil, true, false] do
        assert %GraphError{kind: :invalid_dependency, value: ^value} =
                 invalid_return_error(value)
      end
    end

    test "a string, a number, a function, a nested list, a list holding an alias map" do
      for value <- [
            "a",
            1,
            1.5,
            fn -> :a end,
            [[:a]],
            [:a, [:b]],
            [%{x: :a}],
            [:a, %{x: :b}],
            {:a, :b, :c, :d},
            {:a}
          ] do
        assert %GraphError{} = invalid_return_error(value)
      end
    end

    test "{:ok, keys}, with a message hinting that keys are returned directly" do
      for value <- [{:ok, [:a]}, {:ok, :a}, {:ok, %{x: :a}}] do
        e = invalid_return_error(value)
        assert Exception.message(e) =~ "directly"
      end
    end

    test "a key with no registered rule" do
      for value <- [
            :missing,
            {:missing, %{}},
            {NsA, :a, %{}},
            [:a, :missing],
            %{x: :missing}
          ] do
        assert %GraphError{kind: :unknown_rule} = invalid_return_error(value)
      end
    end

    test "a key with a string ns or name" do
      for value <- [
            {"a", %{}},
            {"default", :a, %{}},
            {:default, "a", %{}},
            ["a"],
            %{x: "a"}
          ] do
        assert %GraphError{} = invalid_return_error(value)
      end
    end

    test "a key with invalid params" do
      for value <- [
            {:a, [id: 1]},
            {:a, 1},
            {:default, :a},
            {:a, %{p: self()}},
            {:a, %{p: [make_ref()]}},
            {:default, :a, %{p: fn -> 1 end}},
            [{:a, %{p: self()}}],
            %{x: {:a, :b}}
          ] do
        assert %GraphError{} = invalid_return_error(value)
      end
    end

    test "a key exposed under the same deps key as a different key to the left of the dependency function" do
      wf =
        Workflow.add_rule(
          base_graph(),
          :r,
          rule([:a, fn _, _, _ -> %{a: :b} end], ok_body(1))
        )

      {e, _} = run_graph_error(wf, [:r])
      assert :shadowing == e.kind

      wf =
        Workflow.add_rule(
          base_graph(),
          :r,
          rule([%{x: :a}, fn _, _, _ -> %{x: :b} end], ok_body(1))
        )

      {e, _} = run_graph_error(wf, [:r])
      assert :shadowing == e.kind
    end

    test "a key exposed under the same deps key as a static dependency to its right" do
      wf =
        Workflow.add_rule(
          base_graph(),
          :r,
          rule([fn _, _, _ -> %{c: :b} end, :c], ok_body(1))
        )

      {e, _} = run_graph_error(wf, [:r])
      assert :shadowing == e.kind
    end

    test "a key exposed under the same deps key as a key returned by another dependency function of the alternative" do
      wf =
        Workflow.add_rule(
          base_graph(),
          :r,
          rule([fn _, _, _ -> %{x: :a} end, fn _, _, _ -> %{x: :b} end], ok_body(1))
        )

      {e, _} = run_graph_error(wf, [:r])
      assert :shadowing == e.kind

      wf =
        Workflow.add_rule(
          base_graph(),
          :r,
          rule([fn _, _, _ -> :a end, fn _, _, _ -> %{a: :b} end], ok_body(1))
        )

      {e, _} = run_graph_error(wf, [:r])
      assert :shadowing == e.kind
    end
  end

  describe "a key returned by a dependency function that is also another dependency of the alternative under the same deps key is accepted and demanded once" do
    test "from a static dependency" do
      {pid, body} = mock_fun(1, ok_body(:va))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([], body))
        |> Workflow.add_rule(:r1, rule([:a, fn _, _, _ -> {:a, %{}} end], deps_body()))
        |> Workflow.add_rule(
          :r2,
          rule([fn _, _, _ -> %{x: :a} end, %{x: :a}], deps_body())
        )

      wf = run!(wf, [:r1, :r2])

      verify(pid)
      assert %{a: :va} == fetch!(wf, :r1)
      assert %{x: :va} == fetch!(wf, :r2)
    end

    test "from another dependency function" do
      {pid, body} = mock_fun(1, ok_body(:va))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([], body))
        |> Workflow.add_rule(
          :r,
          rule(
            [fn _, _, _ -> %{x: :a} end, fn _, _, _ -> %{x: {:default, :a, %{}}} end],
            deps_body()
          )
        )

      wf = run!(wf, [:r])

      verify(pid)
      assert %{x: :va} == fetch!(wf, :r)
    end
  end

  test "a key returned by a dependency function naming an existing rule whose computation fails fails the alternative with {:dep_failed, key}" do
    wf =
      Workflow.add_rule(
        base_graph(),
        :r,
        rule([fn _, _, _ -> {:fail, %{id: 404}} end], ok_body(1))
      )

    assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:r])

    assert {:ok, %{default: {:dep_failed, {:default, :fail, %{id: 404}}}}} ==
             Workflow.attempts(wf, :r)
  end
end
