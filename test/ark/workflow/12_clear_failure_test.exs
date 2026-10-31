defmodule Ark.Workflow.ClearFailureTest do
  use ExUnit.Case, async: true

  import Ark.Test.Mock
  import Ark.Test.WorkflowHelpers
  import ExUnit.CaptureLog

  alias Ark.Workflow
  alias Ark.Workflow.ComputationError
  alias Ark.Workflow.GraphError

  defmodule NsA do
  end

  # A body that fails until `fix/1` is called on the switch.
  defp switch do
    start_log()
  end

  defp fix(switch) do
    track(switch, :fixed)
  end

  defp switch_body(switch, log, name) do
    fn _, _, _ ->
      track(log, name)

      case logged(switch) do
        [] -> {:error, :not_yet}
        _ -> {:ok, name}
      end
    end
  end

  defp tracked(log, name, result) do
    fn _, _, _ ->
      track(log, name)
      result
    end
  end

  defp chain_graph(switch, log) do
    Workflow.new()
    |> Workflow.add_rule(:a, rule([:b], tracked(log, :a, {:ok, :a})))
    |> Workflow.add_rule(:b, rule([:c], tracked(log, :b, {:ok, :b})))
    |> Workflow.add_rule(:c, rule([], switch_body(switch, log, :c)))
  end

  describe "clear_failure on a failed key" do
    test "returns {:ok, workflow} and makes the next run try its alternatives again from the first one" do
      log = start_log()
      sw = switch()

      wf =
        Workflow.add_rule(Workflow.new(), :a, %{
          alts: [
            a1: %{deps: [], body: tracked(log, :a1, {:error, :x})},
            a2: %{deps: [], body: switch_body(sw, log, :a2)}
          ]
        })

      {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a])
      assert [:a1, :a2] == logged(log)

      assert {:ok, wf} = Workflow.clear_failure(wf, :a)
      assert :error == Workflow.fetch(wf, :a)
      assert {:ok, %{}} == Workflow.attempts(wf, :a)

      fix(sw)
      wf = run!(wf, [:a])

      assert [:a1, :a2, :a1, :a2] == logged(log)
      assert :a2 == fetch!(wf, :a)
    end

    test "lets a deploy-added alternative run" do
      log = start_log()

      v1 =
        Workflow.add_rule(Workflow.new(), :a, %{
          alts: [a1: %{deps: [], body: tracked(log, :a1, {:error, :x})}]
        })

      v2 =
        Workflow.add_rule(Workflow.new(), :a, %{
          alts: [
            a1: %{deps: [], body: tracked(log, :a1, {:error, :x})},
            added: %{deps: [], body: tracked(log, :added, {:ok, :added})}
          ]
        })

      {:error, %ComputationError{}, wf} = Workflow.run(v1, [:a])
      wf = roundtrip(wf, v2)
      {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a])

      assert {:ok, wf} = Workflow.clear_failure(wf, :a)
      wf = run!(wf, [:a])

      assert [:a1, :a1, :added] == logged(log)
      assert :added == fetch!(wf, :a)
    end

    test "removes the failure of every key holding {:dep_failed, key}, transitively" do
      log = start_log()
      sw = switch()

      {:error, %ComputationError{}, wf} = Workflow.run(chain_graph(sw, log), [:a])

      assert {:ok, wf} = Workflow.clear_failure(wf, :c)

      for name <- [:a, :b, :c] do
        assert :error == Workflow.fetch(wf, name)
        assert {:ok, %{}} == Workflow.attempts(wf, name)
      end

      fix(sw)
      wf = run!(wf, [:a])

      assert [:c, :c, :b, :a] == logged(log)
      assert :a == fetch!(wf, :a)
    end

    test "keeps the other attempt records of the keys reached by the propagation: the next run retries only the alternatives that failed because of a cleared key" do
      log = start_log()
      sw = switch()

      wf =
        Workflow.new()
        |> Workflow.add_rule(:c, rule([], switch_body(sw, log, :c)))
        |> Workflow.add_rule(:a, %{
          alts: [
            own_failure: %{deps: [], body: tracked(log, :own_failure, {:error, :x})},
            via_c: %{deps: [:c], body: tracked(log, :via_c, {:ok, :via_c})}
          ]
        })

      {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a])
      assert [:own_failure, :c] == logged(log)

      {:ok, wf} = Workflow.clear_failure(wf, :c)
      assert :error == Workflow.fetch(wf, :a)

      assert {:ok, %{own_failure: {:computation_error, _}} = attempts} =
               Workflow.attempts(wf, :a)

      assert 1 == map_size(attempts)

      fix(sw)
      wf = run!(wf, [:a])

      assert [:own_failure, :c, :c, :via_c] == logged(log)
      assert :via_c == fetch!(wf, :a)
    end

    test "retries a cleared alternative placed between alternatives that keep their failure" do
      log = start_log()
      sw = switch()

      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, rule([], switch_body(sw, log, :b)))
        |> Workflow.add_rule(:a, %{
          alts: [
            a1: %{deps: [], body: tracked(log, :a1, {:error, :x})},
            a2: %{deps: [:b], body: tracked(log, :a2, {:ok, :a2})},
            a3: %{deps: [], body: tracked(log, :a3, {:error, :y})}
          ]
        })

      {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a])
      assert [:a1, :b, :a3] == logged(log)

      {:ok, wf} = Workflow.clear_failure(wf, :b)
      assert :error == Workflow.fetch(wf, :a)

      assert {:ok, %{a1: {:computation_error, _}, a3: {:computation_error, _}} = attempts} =
               Workflow.attempts(wf, :a)

      assert 2 == map_size(attempts)

      fix(sw)
      wf = run!(wf, [:a])

      assert [:a1, :b, :a3, :b, :a2] == logged(log)
      assert :a2 == fetch!(wf, :a)
    end

    test "keeps every recorded value" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:ok, const_rule(:value))
        |> Workflow.add_rule(:consumer, rule([:ok, :fail], ok_body(1)))
        |> Workflow.add_rule(:fail, failing_rule())

      {:error, %ComputationError{}, wf} = Workflow.run(wf, [:consumer])
      {:ok, wf} = Workflow.clear_failure(wf, :fail)

      assert {:ok, :value} == Workflow.fetch(wf, :ok)
    end

    test "propagates through orphaned records" do
      log = start_log()

      v1 =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([:orphan], ok_body(:a)))
        |> Workflow.add_rule(:orphan, rule([:c], ok_body(:orphan)))
        |> Workflow.add_rule(:c, failing_rule())

      v2 =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([], tracked(log, :a, {:ok, :a})))
        |> Workflow.add_rule(:c, const_rule(:c))

      {:error, %ComputationError{}, wf} = Workflow.run(v1, [:a])

      capture_log(fn ->
        wf = roundtrip(wf, v2)
        assert {:failed, _} = Workflow.fetch(wf, :a)

        assert {:ok, wf} = Workflow.clear_failure(wf, :c)
        assert :error == Workflow.fetch(wf, :a)

        wf = run!(wf, [:a])
        assert :a == fetch!(wf, :a)
      end)

      assert [:a] == logged(log)
    end

    test "accepts the key forms that run accepts for targets" do
      for key <- [:c, {:c, %{}}, {:default, :c, %{}}] do
        wf = Workflow.add_rule(Workflow.new(), :c, failing_rule())
        {:error, %ComputationError{}, wf} = Workflow.run(wf, [:c])

        assert {:ok, wf} = Workflow.clear_failure(wf, key)
        assert :error == Workflow.fetch(wf, :c)
      end

      wf = Workflow.add_rule(Workflow.new(), {NsA, :c}, failing_rule())
      {:error, %ComputationError{}, wf} = Workflow.run(wf, [{NsA, :c, %{id: 1}}])
      assert {:ok, wf} = Workflow.clear_failure(wf, {NsA, :c, %{id: 1}})
      assert :error == Workflow.fetch(wf, {NsA, :c, %{id: 1}})
    end
  end

  test "when :a needs :b, :b needs :c and :c failed, clearing :c clears :b and :a" do
    {:error, %ComputationError{}, wf} =
      Workflow.run(chain_graph(switch(), start_log()), [:a])

    for name <- [:a, :b, :c] do
      assert {:failed, _} = Workflow.fetch(wf, name)
    end

    {:ok, wf} = Workflow.clear_failure(wf, :c)

    for name <- [:a, :b, :c] do
      assert :error == Workflow.fetch(wf, name)
    end
  end

  test "when :a needs :b then :d, :b needs :c, :d failed in a first run and :c in a second, clearing :c clears :b and :a; the next run of :a computes :c and :b, then fails :a with {:dep_failed, :d} without calling the user code of :d" do
    log = start_log()
    sw = switch()

    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([:b, :d], tracked(log, :a, {:ok, :a})))
      |> Workflow.add_rule(:b, rule([:c], tracked(log, :b, {:ok, :b})))
      |> Workflow.add_rule(:c, rule([], switch_body(sw, log, :c)))
      |> Workflow.add_rule(:d, rule([], tracked(log, :d, {:error, :d})))

    {:error, %ComputationError{}, wf} = Workflow.run(wf, [:d])
    {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a])
    assert [:d, :c] == logged(log)

    assert {:ok, %{default: {:dep_failed, {:default, :b, %{}}}}} ==
             Workflow.attempts(wf, :a)

    {:ok, wf} = Workflow.clear_failure(wf, :c)
    assert :error == Workflow.fetch(wf, :a)
    assert :error == Workflow.fetch(wf, :b)
    assert {:failed, _} = Workflow.fetch(wf, :d)

    fix(sw)
    {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a])

    assert [:d, :c, :c, :b] == logged(log)

    assert {:ok, %{default: {:dep_failed, {:default, :d, %{}}}}} ==
             Workflow.attempts(wf, :a)

    assert :b == fetch!(wf, :b)
  end

  describe "clear_failure with a predicate" do
    setup do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:ok, const_rule(:value))
        |> Workflow.add_rule(:b, failing_rule())
        |> Workflow.add_rule({NsA, :b}, failing_rule())
        |> Workflow.add_rule(:consumer, rule([{NsA, :b, %{id: 1}}], ok_body(1)))
        |> Workflow.add_rule(:other, failing_rule())

      {:ok, wf} = Workflow.run(wf, [:ok])
      {:error, _, wf} = Workflow.run(wf, [{:b, %{id: 1}}])
      {:error, _, wf} = Workflow.run(wf, [{:b, %{id: 2}}])
      {:error, _, wf} = Workflow.run(wf, [:consumer])
      {:error, _, wf} = Workflow.run(wf, [:other])

      %{wf: wf}
    end

    test "clears every failed key it selects, with the same propagation", %{wf: wf} do
      assert {:ok, wf} = Workflow.clear_failure(wf, &match?({_, :b, _}, &1))

      assert :error == Workflow.fetch(wf, {:b, %{id: 1}})
      assert :error == Workflow.fetch(wf, {:b, %{id: 2}})
      assert :error == Workflow.fetch(wf, {NsA, :b, %{id: 1}})
      assert :error == Workflow.fetch(wf, :consumer)
      assert {:failed, _} = Workflow.fetch(wf, :other)
      assert {:ok, :value} == Workflow.fetch(wf, :ok)
    end

    test "receives keys in the full {ns, name, params} form, :default included, failed keys only",
         %{
           wf: wf
         } do
      {pid, pred} = mock_fun(100, fn _ -> false end)

      assert {:error, :not_failed} == Workflow.clear_failure(wf, pred)

      received = pid |> calls() |> Enum.map(&hd/1) |> Enum.sort()

      assert Enum.sort([
               {:default, :b, %{id: 1}},
               {:default, :b, %{id: 2}},
               {NsA, :b, %{id: 1}},
               {:default, :consumer, %{}},
               {:default, :other, %{}}
             ]) == received
    end

    test "is not given orphaned keys", %{wf: wf} do
      reduced = Workflow.add_rule(Workflow.new(), :other, failing_rule())

      capture_log(fn ->
        wf = roundtrip(wf, reduced)
        {pid, pred} = mock_fun(100, fn _ -> true end)

        assert {:ok, _} = Workflow.clear_failure(wf, pred)
        assert [[{:default, :other, %{}}]] == calls(pid)
      end)
    end
  end

  describe "clear_failure returns {:error, :not_failed}" do
    setup do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:ok, const_rule(:value))
        |> Workflow.add_rule(:never, const_rule(:value))
        |> Workflow.add_rule(:fail, failing_rule())
        |> Workflow.add_rule(:in_progress, %{
          alts: [
            in_progress1: %{deps: [], body: error_body()},
            in_progress2: %{deps: [fn _, _, _ -> "invalid" end], body: ok_body(1)}
          ]
        })

      {:ok, wf} = Workflow.run(wf, [:ok])
      {:error, %GraphError{}, wf} = Workflow.run(wf, [:in_progress])
      %{wf: wf}
    end

    test "for a key with a value", %{wf: wf} do
      assert {:error, :not_failed} == Workflow.clear_failure(wf, :ok)
    end

    test "for a key with attempts but no result", %{wf: wf} do
      assert {:error, :not_failed} == Workflow.clear_failure(wf, :in_progress)
    end

    test "for a key with no records", %{wf: wf} do
      assert {:error, :not_failed} == Workflow.clear_failure(wf, :never)
      assert {:error, :not_failed} == Workflow.clear_failure(wf, {:fail, %{id: 1}})
    end

    test "for a predicate that selects no key", %{wf: wf} do
      assert {:error, :not_failed} == Workflow.clear_failure(wf, fn _ -> true end)
    end

    test "for a consumer already cleared by the propagation from its dependency" do
      {:error, %ComputationError{}, wf} =
        Workflow.run(chain_graph(switch(), start_log()), [:a])

      {:ok, wf} = Workflow.clear_failure(wf, :c)
      assert {:error, :not_failed} == Workflow.clear_failure(wf, :a)
      assert {:error, :not_failed} == Workflow.clear_failure(wf, :b)
    end
  end

  test "clear_failure for a key with no registered rule returns a graph error" do
    wf = Workflow.add_rule(Workflow.new(), :a, failing_rule())

    assert {:error,
            %GraphError{rule: nil, reason: {:unknown_rule, {:default, :missing, %{}}}}} =
             Workflow.clear_failure(wf, :missing)

    assert {:error, %GraphError{reason: {:unknown_rule, {NsA, :a, %{}}}}} =
             Workflow.clear_failure(wf, {NsA, :a, %{}})

    assert {:error, %GraphError{reason: {:invalid_key, "a"}}} =
             Workflow.clear_failure(wf, "a")
  end

  test "clear_failure result survives a dump and a load" do
    log = start_log()
    sw = switch()
    graph = chain_graph(sw, log)

    {:error, %ComputationError{}, wf} = Workflow.run(graph, [:a])
    {:ok, wf} = Workflow.clear_failure(wf, :c)

    wf = roundtrip(wf, graph)

    for name <- [:a, :b, :c] do
      assert :error == Workflow.fetch(wf, name)
      assert {:ok, %{}} == Workflow.attempts(wf, name)
    end

    fix(sw)
    wf = run!(wf, [:a])
    assert :a == fetch!(wf, :a)
  end
end
