defmodule Ark.Workflow.DependencyFunctionsTest do
  use ExUnit.Case, async: true

  import Ark.Test.Mock
  import Ark.Test.WorkflowHelpers

  alias Ark.Workflow
  alias Ark.Workflow.ComputationError
  alias Ark.Workflow.GraphError

  defmodule NsA do
  end

  defmodule SomeStruct do
    defstruct [:id, :tags]
  end

  defmodule DomainError do
    defexception [:message]
  end

  def mfa_body(params, deps, ctx, log, extra) do
    track(log, {:mfa_body, params, deps, ctx, extra})
    {:ok, :from_mfa}
  end

  def mfa_deps(params, deps, ctx, log, extra) do
    track(log, {:mfa_deps, params, deps, ctx, extra})
    %{y: :b}
  end

  def capture_body(params, deps, %{log: log} = ctx) do
    track(log, {:capture_body, params, deps, ctx})
    {:ok, :from_capture}
  end

  def capture_deps(params, deps, %{log: log} = ctx) do
    track(log, {:capture_deps, params, deps, ctx})
    %{y: :b}
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

  defp deps_attempt_error(deps_fun) do
    wf = Workflow.add_rule(Workflow.new(), :r, rule([deps_fun], ok_body(1)))
    assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:r])
    assert {:ok, %{default: {:computation_error, cleaned}}} = Workflow.attempts(wf, :r)
    cleaned
  end

  defp run_graph_error(wf, targets) do
    assert {:error, %GraphError{} = e, wf} = Workflow.run(wf, targets)
    {e, wf}
  end

  defp key(name, params \\ %{}) do
    {:default, name, params}
  end

  defp invalid_return_error(value) do
    fun = fn _, _, _ -> value end
    wf = Workflow.add_rule(base_graph(), :r, rule([:a, fun], ok_body(1)))

    {e, _} = run_graph_error(wf, [:r])

    assert %GraphError{
             rule: {:default, :r},
             key: {:default, :r, %{}},
             alternative: :default,
             reason: {:bad_return, :deps, ^fun, ^value, _}
           } = e

    e
  end

  defp invalid_return_reason(value) do
    {:bad_return, :deps, _, _, key_reason} = invalid_return_error(value).reason
    key_reason
  end

  defp shadowing_reason(deps) do
    wf = Workflow.add_rule(base_graph(), :r, rule(deps, ok_body(1)))
    {e, _} = run_graph_error(wf, [:r])
    assert {:bad_return, :deps, fun, _, {:shadowing, _, _} = shadowing} = e.reason
    {fun, shadowing_exposures(shadowing)}
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
      {pid, never} = mock_never(fn _, _, _ -> :a end)
      wf = Workflow.add_rule(base_graph(), :r, rule([:a, :fail, never], ok_body(1)))

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

    test "as a list are exposed under their written forms" do
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

      assert %{
               :a => :va,
               {:b, %{}} => :vb,
               {:default, :c, %{}} => :vc,
               {NsA, :n, %{id: 1}} => %{id: 1}
             } == fetch!(wf, :r)
    end

    test "as a single key are exposed under its written form" do
      wf =
        base_graph()
        |> Workflow.add_rule(:p, rule([], params_body()))
        |> Workflow.add_rule(
          :r1,
          rule([fn _, _, _ -> {:default, :a, %{}} end], deps_body())
        )
        |> Workflow.add_rule(:r2, rule([fn _, _, _ -> {:p, %{id: 1}} end], deps_body()))

      wf = run!(wf, [:r1, :r2])

      assert %{{:default, :a, %{}} => :va} == fetch!(wf, :r1)
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

    {e, wf} = run_graph_error(wf, [:r])

    assert %GraphError{rule: {:default, :broken}, reason: {:bad_return, :deps, _, _, _}} =
             e

    assert {:ok, :vb} == Workflow.fetch(wf, :b)

    track(phase, :second)
    wf = run!(wf, [:r])

    assert %{c: :vc} == fetch!(wf, :r)
    assert {:ok, :vb} == Workflow.fetch(wf, :b)
  end

  describe "a dependency function that" do
    defp failing_deps_attempt(deps_fun) do
      {pid, never} = mock_never(ok_body(1))

      wf =
        Workflow.add_rule(base_graph(), :r, %{
          alts: [
            r1: %{deps: [:a, deps_fun], body: never},
            r2: %{deps: [], body: ok_body(:r2)}
          ]
        })

      wf = run!(wf, [:r])
      wf |> dbg()
      verify(pid)
      assert :r2 == fetch!(wf, :r)
      assert {:ok, %{r1: {:computation_error, cleaned}}} = Workflow.attempts(wf, :r)
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
            r1: %{deps: [], body: error_body()},
            r2: %{deps: [:a, fn _, _, _ -> "invalid" end], body: ok_body(1)}
          ]
        })
        |> Workflow.add_rule(:top, rule([{:r, %{id: 1}}], ok_body(1)))

      %{wf: wf, a_pid: a_pid}
    end

    test "carrying the returned value, and the key and alternative whose dependency function returned it",
         %{wf: wf} do
      {e, _} = run_graph_error(wf, [:top])

      assert {:bad_return, :deps, _, "invalid", {:invalid_key, "invalid"}} = e.reason
      assert {:default, :r} == e.rule
      assert {:default, :r, %{id: 1}} == e.key
      assert :r2 == e.alternative
    end

    test "returned with the workflow and every fact recorded before", %{
      wf: wf,
      a_pid: a_pid
    } do
      {_, wf} = run_graph_error(wf, [:top])

      verify(a_pid)
      assert {:ok, :va} == Workflow.fetch(wf, :a)

      assert {:ok, %{r1: {:computation_error, _}}} =
               Workflow.attempts(wf, {:r, %{id: 1}})
    end

    test "recording nothing for the key whose dependency function returned it", %{wf: wf} do
      {_, wf} = run_graph_error(wf, [:top])

      assert :error == Workflow.fetch(wf, {:r, %{id: 1}})
      assert {:ok, attempts} = Workflow.attempts(wf, {:r, %{id: 1}})
      refute Map.has_key?(attempts, :r2)
      assert :error == Workflow.fetch(wf, :top)
      assert {:ok, %{}} == Workflow.attempts(wf, :top)
    end
  end

  describe "invalid dependencies, each a graph error" do
    test "nil, true and false, reported as invalid returns, not as keys with no rule" do
      for value <- [nil, true, false] do
        assert {:invalid_key, value} == invalid_return_reason(value)
      end
    end

    test "a string, a number, a function, a nested list, a list holding an alias map" do
      for value <- ["a", 1, 1.5, fn -> :a end, {:a, :b, :c, :d}, {:a}] do
        assert {:invalid_key, value} == invalid_return_reason(value)
      end

      for {value, given} <- [
            {[[:a]], [:a]},
            {[:a, [:b]], [:b]},
            {[%{x: :a}], %{x: :a}},
            {[:a, %{x: :b}], %{x: :b}}
          ] do
        assert {:invalid_key, given} == invalid_return_reason(value)
      end
    end

    test "{:ok, keys}, with a message hinting that keys are returned directly" do
      for value <- [{:ok, [:a]}, {:ok, :a}, {:ok, %{x: :a}}] do
        e = invalid_return_error(value)
        assert Exception.message(e) =~ "directly"
      end
    end

    test "a key with no registered rule" do
      for {value, key} <- [
            {:missing, key(:missing)},
            {{:missing, %{}}, key(:missing)},
            {{NsA, :a, %{}}, {NsA, :a, %{}}},
            {[:a, :missing], key(:missing)},
            {%{x: :missing}, key(:missing)}
          ] do
        assert {:unknown_rule, key} == invalid_return_reason(value)
      end
    end

    test "a key with a string ns or name" do
      for {value, given} <- [
            {{"a", %{}}, {"a", %{}}},
            {{"default", :a, %{}}, {"default", :a, %{}}},
            {{:default, "a", %{}}, {:default, "a", %{}}},
            {["a"], "a"},
            {%{x: "a"}, "a"}
          ] do
        assert {:invalid_key, given} == invalid_return_reason(value)
      end
    end

    test "a key with invalid params" do
      for value <- [
            {:a, [id: 1]},
            {:a, 1},
            {:default, :a},
            {:a, %{p: self()}},
            {:a, %{p: [make_ref()]}},
            {:default, :a, %{p: fn -> 1 end}}
          ] do
        assert {:invalid_params, value} == invalid_return_reason(value)
      end

      for {value, given} <- [
            {[{:a, %{p: self()}}], {:a, %{p: self()}}},
            {%{x: {:a, :b}}, {:a, :b}}
          ] do
        assert {:invalid_params, given} == invalid_return_reason(value)
      end
    end

    @tag :skip
    test "a key exposed under the same deps key as a different key to the left of the dependency function" do
      fun = fn _, _, _ -> %{a: :b} end

      assert {fun, MapSet.new([{:a, key(:a), :key}, {:a, key(:b), :alias}])} ==
               shadowing_reason([:a, fun])

      fun = fn _, _, _ -> %{x: :b} end

      assert {fun, MapSet.new([{:x, key(:a), :alias}, {:x, key(:b), :alias}])} ==
               shadowing_reason([%{x: :a}, fun])
    end

    @tag :skip
    test "a key exposed under the same deps key as a static dependency to its right" do
      fun = fn _, _, _ -> %{c: :b} end

      assert {fun, MapSet.new([{:c, key(:b), :alias}, {:c, key(:c), :key}])} ==
               shadowing_reason([fun, :c])
    end

    @tag :skip
    test "a key exposed under the same deps key as a key returned by another dependency function of the alternative" do
      fun = fn _, _, _ -> %{x: :b} end

      assert {fun, MapSet.new([{:x, key(:a), :alias}, {:x, key(:b), :alias}])} ==
               shadowing_reason([fn _, _, _ -> %{x: :a} end, fun])

      fun = fn _, _, _ -> %{a: :b} end

      assert {fun, MapSet.new([{:a, key(:a), :key}, {:a, key(:b), :alias}])} ==
               shadowing_reason([fn _, _, _ -> :a end, fun])
    end
  end

  describe "a key returned by a dependency function that is also another dependency of the alternative under the same deps key is accepted and demanded once" do
    test "from a static dependency" do
      {pid, body} = mock_fun(1, ok_body(:va))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([], body))
        |> Workflow.add_rule(:r1, rule([:a, fn _, _, _ -> :a end], deps_body()))
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

  test "a key returned by a dependency function that is also another dependency of the alternative in another written form is demanded once and exposed under both forms" do
    {pid, body} = mock_fun(1, ok_body(:va))

    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([], body))
      |> Workflow.add_rule(:r, rule([:a, fn _, _, _ -> {:a, %{}} end], deps_body()))

    wf = run!(wf, [:r])

    verify(pid)
    assert %{:a => :va, {:a, %{}} => :va} == fetch!(wf, :r)
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

  describe "run" do
    test "never raises: graph errors are returned with the workflow" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:ok, const_rule(1))
        |> Workflow.add_rule(:bad_dep, rule([fn _, _, _ -> "not a key" end], ok_body(1)))
        |> Workflow.add_rule(:unknown_dep, rule([fn _, _, _ -> :nope end], ok_body(1)))

      assert {:error, %GraphError{reason: {:unknown_rule, _}}, %Workflow{}} =
               Workflow.run(wf, [:missing])

      assert {:error, %GraphError{reason: {:invalid_key, "string"}}, %Workflow{}} =
               Workflow.run(wf, ["string"])

      assert {:error, e, wf2} = Workflow.run(wf, [:ok, :bad_dep])
      assert {:bad_return, :deps, _, "not a key", {:invalid_key, "not a key"}} = e.reason
      assert {:ok, 1} == Workflow.fetch(wf2, :ok)

      assert {:error, e, %Workflow{}} = Workflow.run(wf, [:unknown_dep])

      assert {:bad_return, :deps, _, :nope, {:unknown_rule, {:default, :nope, %{}}}} =
               e.reason
    end
  end

  describe "fetch" do
    setup do
      wf =
        Workflow.add_rule(Workflow.new(), :in_progress, %{
          alts: [
            in_progress1: %{deps: [], body: error_body()},
            in_progress2: %{deps: [fn _, _, _ -> "not a key" end], body: ok_body(1)}
          ]
        })

      {:error, %GraphError{reason: {:bad_return, :deps, _, _, _}}, wf} =
        Workflow.run(wf, [:in_progress])

      %{wf: wf}
    end

    test "returns :error for a key with attempts but no result", %{wf: wf} do
      assert :error == Workflow.fetch(wf, :in_progress)

      assert {:ok, %{in_progress1: {:computation_error, _}}} =
               Workflow.attempts(wf, :in_progress)
    end
  end

  describe "a body receives params exactly as written by the code that demanded the key" do
    test "from a key returned by a dependency function" do
      {pid, body} = mock_fun(1, ok_body(1))
      params = %{"id" => 1, :opt => [1, 2.0], :s => %SomeStruct{id: 3}}

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([], body))
        |> Workflow.add_rule(:r, rule([fn _, _, _ -> {:a, params} end], deps_body()))

      _ = run!(wf, [:r])

      verify(pid)
      assert [[^params, %{}, %{}]] = calls(pid)
    end
  end

  test "a body of a key demanded without params receives %{}" do
    {pid, body} = mock_fun(3, ok_body(1))

    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([], body))
      |> Workflow.add_rule({NsA, :b}, rule([], body))
      |> Workflow.add_rule(:c, rule([], body))
      |> Workflow.add_rule(:r, rule([{NsA, :b, %{}}, fn _, _, _ -> :c end], deps_body()))

    _ = run!(wf, [:a, :r])

    verify(pid)
    assert [[%{}, _, _], [%{}, _, _], [%{}, _, _]] = calls(pid)
  end

  describe "the deps map given to a body" do
    test "holds every dependency of the alternative, static and dynamic" do
      wf =
        Enum.reduce([:a, :b, :c, :d, :e, :f], Workflow.new(), fn name, wf ->
          Workflow.add_rule(wf, name, const_rule(name))
        end)

      wf =
        Workflow.add_rule(
          wf,
          :r,
          rule(
            [
              :a,
              fn _, _, _ -> :b end,
              %{x: :c},
              fn _, _, _ -> %{y: :d} end,
              fn _, _, _ -> [:e, {:f, %{}}] end
            ],
            deps_body()
          )
        )

      wf = run!(wf, [:r])

      assert %{:a => :a, :b => :b, :x => :c, :y => :d, :e => :e, {:f, %{}} => :f} ==
               fetch!(wf, :r)
    end

    test "exposes an aliased dependency under its alias, whatever the term used as alias" do
      aliases = ["string", {:tuple, 1}, 1, 2.5, %{k: 1}, [:l], nil, true, :atom, NsA]

      wf =
        Enum.reduce(Enum.with_index(aliases), Workflow.new(), fn {_, i}, wf ->
          Workflow.add_rule(wf, :"k#{i}", const_rule(i))
        end)

      static_map = Map.new(Enum.with_index(aliases), fn {a, i} -> {a, :"k#{i}"} end)

      wf =
        wf
        |> Workflow.add_rule(:static, rule([static_map], deps_body()))
        |> Workflow.add_rule(:dynamic, rule([fn _, _, _ -> static_map end], deps_body()))

      wf = run!(wf, [:static, :dynamic])

      expected = Map.new(Enum.with_index(aliases))
      assert expected == fetch!(wf, :static)
      assert expected == fetch!(wf, :dynamic)
    end
  end

  describe "in a dependency list" do
    test "a {module, function, list} tuple is called as a dependency function" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, const_rule(:vb))
        |> Workflow.add_rule(
          :r,
          rule([{__MODULE__, :return_key, [%{x: :b}]}], deps_body())
        )

      wf = run!(wf, [:r])
      assert %{x: :vb} == fetch!(wf, :r)
    end

    test "a remote capture is called as a dependency function" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, const_rule(:vb))
        |> Workflow.add_rule(:r, rule([&__MODULE__.return_b/3], deps_body()))

      wf = run!(wf, [:r])
      assert %{b: :vb} == fetch!(wf, :r)
    end
  end

  describe "a body and a dependency function are called with params, deps and context" do
    test "as an anonymous function" do
      {deps_pid, deps_fun} = mock_fun(1, fn _, _, _ -> %{y: :b} end)
      {body_pid, body} = mock_fun(1, ok_body(:from_fun))

      wf = Workflow.add_rule(base_graph(), :r, rule([%{x: :a}, deps_fun], body))
      wf = run!(wf, [{:r, %{id: 1}}], context: %{ctx: 1})

      verify(deps_pid)
      verify(body_pid)
      assert [[%{id: 1}, %{x: :va}, %{ctx: 1}]] == calls(deps_pid)
      assert [[%{id: 1}, %{x: :va, y: :vb}, %{ctx: 1}]] == calls(body_pid)
      assert :from_fun == fetch!(wf, {:r, %{id: 1}})
    end

    test "as a {module, function, extra_args} tuple, with extra_args appended after the engine's arguments" do
      log = start_log()

      wf =
        Workflow.add_rule(
          base_graph(),
          :r,
          rule(
            [%{x: :a}, {__MODULE__, :mfa_deps, [log, :e1]}],
            {__MODULE__, :mfa_body, [log, :e2]}
          )
        )

      wf = run!(wf, [{:r, %{id: 1}}], context: %{ctx: 1})

      assert [
               {:mfa_deps, %{id: 1}, %{x: :va}, %{ctx: 1}, :e1},
               {:mfa_body, %{id: 1}, %{x: :va, y: :vb}, %{ctx: 1}, :e2}
             ] == logged(log)

      assert :from_mfa == fetch!(wf, {:r, %{id: 1}})
    end

    test "as a remote capture" do
      log = start_log()

      wf =
        Workflow.add_rule(
          base_graph(),
          :r,
          rule([%{x: :a}, &__MODULE__.capture_deps/3], &__MODULE__.capture_body/3)
        )

      wf = run!(wf, [{:r, %{id: 1}}], context: %{log: log})

      assert [
               {:capture_deps, %{id: 1}, %{x: :va}, %{log: log}},
               {:capture_body, %{id: 1}, %{x: :va, y: :vb}, %{log: log}}
             ] == logged(log)

      assert :from_capture == fetch!(wf, {:r, %{id: 1}})
    end
  end

  @tag :skip
  test "a dependency function that raises, throws or exits records the same reason and stacktrace as a body would" do
    assert %{
             kind: :error,
             reason: %DomainError{message: "domain failure"},
             stacktrace: st
           } =
             deps_attempt_error(fn _, _, _ -> raise DomainError, "domain failure" end)

    assert st =~ "06_dependency_functions_test.exs"

    assert %{kind: :error, reason: %ArgumentError{}, stacktrace: st} =
             deps_attempt_error(fn _, _, _ -> :erlang.error(:badarg) end)

    assert st =~ "06_dependency_functions_test.exs"

    assert %{kind: :throw, reason: {:thrown, 1}, stacktrace: st} =
             deps_attempt_error(fn _, _, _ -> throw({:thrown, 1}) end)

    assert st =~ "06_dependency_functions_test.exs"

    assert %{kind: :exit, reason: {:shutdown, :x}, stacktrace: st} =
             deps_attempt_error(fn _, _, _ -> exit({:shutdown, :x}) end)

    assert st =~ "06_dependency_functions_test.exs"
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
end
