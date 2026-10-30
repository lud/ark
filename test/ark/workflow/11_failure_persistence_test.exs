defmodule Ark.Workflow.FailurePersistenceTest do
  use ExUnit.Case, async: true

  import Ark.Test.Mock
  import Ark.Test.WorkflowHelpers
  import ExUnit.CaptureLog

  alias Ark.Workflow
  alias Ark.Workflow.ComputationError
  alias Ark.Workflow.GraphError

  defp tracked(log, name, result) do
    fn _, _, _ ->
      track(log, name)
      result
    end
  end

  defp alt(log, name, result) do
    {name, %{deps: [], body: tracked(log, name, result)}}
  end

  defp alts_rule(alts) do
    %{alts: alts}
  end

  defp graph_with(name, rule_map) do
    Workflow.add_rule(Workflow.new(), name, rule_map)
  end

  # Stops a run after the first alternative of :a failed, before the next
  # alternative is attempted: the next alternative demands a key whose
  # dependency function returns an invalid dependency.
  defp interrupted_rule(log) do
    alts_rule([
      alt(log, :a1, {:error, :x}),
      {:a2, %{deps: [:broken], body: tracked(log, :a2, {:ok, :a2})}}
    ])
  end

  defp broken_rule do
    rule([fn _, _, _ -> "invalid" end], ok_body(1))
  end

  @tag :skip
  test "a failure is scoped to the exact key" do
    log = start_log()

    wf =
      graph_with(
        :a,
        alts_rule([
          {:a1,
           %{
             deps: [],
             body: fn %{id: id}, _, _ ->
               track(log, {:a1, id})

               if id == 1 do
                 {:error, :x}
               else
                 {:ok, :a1}
               end
             end
           }},
          {:a2,
           %{
             deps: [],
             body: fn %{id: id}, _, _ ->
               track(log, {:a2, id})
               {:ok, :a2}
             end
           }}
        ])
      )

    wf = run!(wf, [{:a, %{id: 1}}, {:a, %{id: 2}}])

    assert [{:a1, 1}, {:a2, 1}, {:a1, 2}] == logged(log)
    assert :a2 == fetch!(wf, {:a, %{id: 1}})
    assert :a1 == fetch!(wf, {:a, %{id: 2}})
    assert {:ok, %{}} == Workflow.attempts(wf, {:a, %{id: 2}})
  end

  describe "a failed key stays failed" do
    @tag :skip
    test "on a later run of the same state: no user code is called for it" do
      {pid, body} = mock_fun(1, error_body())
      wf = graph_with(:a, rule([], body))

      {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a])
      {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a])

      verify(pid)
      assert {:failed, _} = Workflow.fetch(wf, :a)
    end

    @tag :skip
    test "after a dump and a load" do
      {pid, body} = mock_fun(1, error_body())
      graph = graph_with(:a, rule([], body))

      {:error, %ComputationError{}, wf} = Workflow.run(graph, [:a])
      wf = roundtrip(wf, graph)
      {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a])

      verify(pid)
      assert {:failed, _} = Workflow.fetch(wf, :a)
    end

    @tag :skip
    test "when a deploy adds alternatives to its rule" do
      log = start_log()
      v1 = graph_with(:a, alts_rule([alt(log, :a1, {:error, :x})]))

      v2 =
        graph_with(
          :a,
          alts_rule([alt(log, :a1, {:error, :x}), alt(log, :a2, {:ok, 2})])
        )

      {:error, %ComputationError{}, wf} = Workflow.run(v1, [:a])
      wf = roundtrip(wf, v2)
      {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a])

      assert [:a1] == logged(log)
      assert {:failed, {:all_alternatives_failed, [:a1]}} == Workflow.fetch(wf, :a)
    end
  end

  describe "a key with a value keeps it, and none of its alternatives is called again" do
    test "on a later run of the same state" do
      {pid, body} = mock_fun(1, ok_body(1))
      wf = graph_with(:a, rule([], body))

      wf = run!(wf, [:a])
      wf = run!(wf, [:a])

      verify(pid)
      assert 1 == fetch!(wf, :a)
    end

    @tag :skip
    test "after a dump and a load" do
      {pid, body} = mock_fun(1, ok_body(1))
      graph = graph_with(:a, rule([], body))

      wf = run!(graph, [:a])
      wf = roundtrip(wf, graph)
      wf = run!(wf, [:a])

      verify(pid)
      assert 1 == fetch!(wf, :a)
    end

    @tag :skip
    test "when a deploy adds, removes or reorders alternatives" do
      log = start_log()

      v1 =
        graph_with(
          :a,
          alts_rule([alt(log, :a1, {:error, :x}), alt(log, :a2, {:ok, :a2})])
        )

      wf = run!(v1, [:a])
      assert [:a1, :a2] == logged(log)

      for alts <- [
            [
              alt(log, :a0, {:ok, :a0}),
              alt(log, :a1, {:error, :x}),
              alt(log, :a2, {:ok, :a2})
            ],
            [alt(log, :a1, {:error, :x})],
            [alt(log, :a2, {:ok, :a2}), alt(log, :a1, {:error, :x})],
            [alt(log, :other, {:ok, :other})]
          ] do
        capture_log(fn ->
          loaded = roundtrip(wf, graph_with(:a, alts_rule(alts)))
          loaded = run!(loaded, [:a])
          assert :a2 == fetch!(loaded, :a)
        end)
      end

      assert [:a1, :a2] == logged(log)
    end
  end

  @tag :skip
  test "a value produced by an alternative that a deploy then removed is given to consumers demanded after the deploy" do
    v1 =
      Workflow.new()
      |> Workflow.add_rule(
        :a,
        alts_rule(removed: %{deps: [], body: ok_body(:from_removed)})
      )
      |> Workflow.add_rule(:consumer, rule([:a], deps_body()))

    v2 =
      Workflow.new()
      |> Workflow.add_rule(:a, alts_rule(kept: %{deps: [], body: ok_body(:from_kept)}))
      |> Workflow.add_rule(:consumer, rule([:a], deps_body()))

    wf = run!(v1, [:a])

    capture_log(fn ->
      wf = roundtrip(wf, v2)
      wf = run!(wf, [:consumer])
      assert %{a: :from_removed} == fetch!(wf, :consumer)
    end)
  end

  @tag :skip
  test "a run stopped between the failure of A1 and the attempt of A2 resumes at A2, without calling A1 again" do
    log = start_log()

    graph = fn broken ->
      Workflow.new()
      |> Workflow.add_rule(:a, interrupted_rule(log))
      |> Workflow.add_rule(:broken, broken)
    end

    {:error, %GraphError{}, wf} = Workflow.run(graph.(broken_rule()), [:a])
    assert [:a1] == logged(log)

    wf = roundtrip(wf, graph.(const_rule(:fixed)))
    wf = run!(wf, [:a])

    assert [:a1, :a2] == logged(log)
    assert :a2 == fetch!(wf, :a)
  end

  @tag :skip
  test "after a deploy reorders alternatives, recorded attempts stay attached to their alternative name, and the current order decides which alternative is tried next" do
    log = start_log()

    v1 = fn broken ->
      Workflow.new()
      |> Workflow.add_rule(
        :a,
        alts_rule([
          alt(log, :a1, {:error, :x}),
          {:a2, %{deps: [:broken], body: tracked(log, :a2, {:error, :x})}},
          alt(log, :a3, {:ok, :a3})
        ])
      )
      |> Workflow.add_rule(:broken, broken)
    end

    {:error, %GraphError{}, wf} = Workflow.run(v1.(broken_rule()), [:a])
    assert [:a1] == logged(log)

    v2 =
      Workflow.new()
      |> Workflow.add_rule(
        :a,
        alts_rule([
          alt(log, :a3, {:error, :x}),
          alt(log, :a1, {:ok, :a1}),
          alt(log, :a2, {:ok, :a2})
        ])
      )
      |> Workflow.add_rule(:broken, const_rule(:fixed))

    wf = roundtrip(wf, v2)
    wf = run!(wf, [:a])

    assert [:a1, :a3, :a2] == logged(log)
    assert :a2 == fetch!(wf, :a)

    assert {:ok, %{a1: {:computation_error, _}, a3: {:computation_error, _}}} =
             Workflow.attempts(wf, :a)
  end

  describe "after a deploy" do
    @tag :skip
    test "inserts an alternative before one that failed, the inserted one is tried next" do
      log = start_log()

      graph = fn alts ->
        Workflow.new()
        |> Workflow.add_rule(:a, alts_rule(alts))
        |> Workflow.add_rule(:broken, broken_rule())
      end

      v1 =
        graph.([alt(log, :a1, {:error, :x}), {:a2, %{deps: [:broken], body: ok_body(1)}}])

      {:error, %GraphError{}, wf} = Workflow.run(v1, [:a])

      v2 =
        graph.([
          alt(log, :new, {:ok, :new}),
          alt(log, :a1, {:ok, :a1}),
          {:a2, %{deps: [:broken], body: ok_body(1)}}
        ])

      wf = roundtrip(wf, v2)
      wf = run!(wf, [:a])

      assert [:a1, :new] == logged(log)
      assert :new == fetch!(wf, :a)
    end

    @tag :skip
    test "removes the untried alternatives of a key, the key is failed on resume without calling user code" do
      log = start_log()

      v1 =
        Workflow.new()
        |> Workflow.add_rule(:a, interrupted_rule(log))
        |> Workflow.add_rule(:broken, broken_rule())

      {:error, %GraphError{}, wf} = Workflow.run(v1, [:a])

      v2 = graph_with(:a, alts_rule([alt(log, :a1, {:ok, :a1})]))

      capture_log(fn ->
        wf = roundtrip(wf, v2)
        assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a])
        assert {:failed, {:all_alternatives_failed, [:a1]}} == Workflow.fetch(wf, :a)
      end)

      assert [:a1] == logged(log)
    end

    @tag :skip
    test "renames an alternative, the renamed one is tried again, and the records under the old name are orphaned" do
      log = start_log()

      v1 =
        Workflow.new()
        |> Workflow.add_rule(:a, interrupted_rule(log))
        |> Workflow.add_rule(:broken, broken_rule())

      {:error, %GraphError{}, wf} = Workflow.run(v1, [:a])

      v2 =
        Workflow.new()
        |> Workflow.add_rule(
          :a,
          alts_rule([alt(log, :renamed, {:error, :y}), alt(log, :a2, {:ok, :a2})])
        )
        |> Workflow.add_rule(:broken, const_rule(:fixed))

      capture_log(fn ->
        wf = roundtrip(wf, v2)
        wf = run!(wf, [:a])
        assert :a2 == fetch!(wf, :a)
        assert {:ok, attempts} = Workflow.attempts(wf, :a)
        assert %{renamed: {:computation_error, _}} = attempts
        assert {:computation_error, _} = attempts["a1"]
      end)

      assert [:a1, :renamed, :a2] == logged(log)
    end

    @tag :skip
    test "removed an alternative, a key that failed before the dump still lists that alternative in {:all_alternatives_failed, _}, by its name as a string" do
      graph = fn alts -> graph_with(:a, alts_rule(alts)) end
      log = start_log()

      v1 =
        graph.([alt(log, :kept, {:error, :x}), alt(log, :removed_alt_name, {:error, :y})])

      {:error, %ComputationError{}, wf} = Workflow.run(v1, [:a])

      capture_log(fn ->
        wf = roundtrip(wf, graph.([alt(log, :kept, {:error, :x})]))

        assert {:failed, {:all_alternatives_failed, [:kept, "removed_alt_name"]}} ==
                 Workflow.fetch(wf, :a)
      end)
    end
  end

  describe "attempt records of a removed alternative" do
    setup do
      log = start_log()

      v1 =
        Workflow.new()
        |> Workflow.add_rule(
          :a,
          alts_rule([
            alt(log, :removed, {:error, :x}),
            {:a2, %{deps: [:broken], body: tracked(log, :a2, {:ok, :a2})}},
            alt(log, :a3, {:ok, :a3})
          ])
        )
        |> Workflow.add_rule(:broken, broken_rule())

      {:error, %GraphError{}, wf} = Workflow.run(v1, [:a])
      assert [:removed] == logged(log)

      %{log: log, wf: wf}
    end

    @tag :skip
    test "take no part in evaluation", %{log: log, wf: wf} do
      v2 =
        Workflow.new()
        |> Workflow.add_rule(
          :a,
          alts_rule([alt(log, :a2, {:error, :z}), alt(log, :a3, {:ok, :a3})])
        )
        |> Workflow.add_rule(:broken, const_rule(:fixed))

      capture_log(fn ->
        wf = roundtrip(wf, v2)
        wf = run!(wf, [:a])
        assert :a3 == fetch!(wf, :a)
      end)

      assert [:removed, :a2, :a3] == logged(log)
    end

    @tag :skip
    test "are honored again when the alternative is added back, also after a dump and a load: it is not tried again",
         %{log: log, wf: wf} do
      without =
        Workflow.new()
        |> Workflow.add_rule(
          :a,
          alts_rule([{:a2, %{deps: [:broken], body: tracked(log, :a2, {:ok, :a2})}}])
        )
        |> Workflow.add_rule(:broken, broken_rule())

      with_it =
        Workflow.new()
        |> Workflow.add_rule(
          :a,
          alts_rule([alt(log, :removed, {:ok, :removed}), alt(log, :a3, {:ok, :a3})])
        )
        |> Workflow.add_rule(:broken, const_rule(:fixed))

      capture_log(fn ->
        wf = roundtrip(wf, without)
        {:error, %GraphError{}, wf} = Workflow.run(wf, [:a])
        wf = roundtrip(wf, with_it)
        wf = run!(wf, [:a])
        assert :a3 == fetch!(wf, :a)
      end)

      assert [:removed, :a3] == logged(log)
    end
  end

  test "the failures of a key hold the orphaned records reachable from it: attempt records of a removed alternative, and a key whose rule was removed" do
    v1 =
      Workflow.new()
      |> Workflow.add_rule(
        :a,
        alts_rule([
          {:gone, %{deps: [], body: error_body(:gone_reason)}},
          {:kept, %{deps: [:orphan], body: ok_body(:a)}}
        ])
      )
      |> Workflow.add_rule(:orphan, rule([:c], ok_body(:orphan)))
      |> Workflow.add_rule(:c, failing_rule(:c_reason))

    v2 =
      Workflow.new()
      |> Workflow.add_rule(:a, alts_rule([{:kept, %{deps: [], body: ok_body(:a)}}]))
      |> Workflow.add_rule(:c, failing_rule(:c_reason))

    {:error, %ComputationError{}, wf} = Workflow.run(v1, [:a])

    capture_log(fn ->
      wf = roundtrip(wf, v2)
      a = {:default, :a, %{}}
      c = {:default, :c, %{}}

      assert {:ok, failures} = Workflow.failures(wf, :a)
      assert 3 == map_size(failures)

      assert %{
               ^a => %{
                 "gone" => {:computation_error, %{message: ":gone_reason"}},
                 kept: {:dep_failed, orphan}
               },
               ^c => %{default: {:computation_error, %{message: ":c_reason"}}}
             } = failures

      assert 2 == map_size(failures[a])
      assert [{:dep_failed, ^c}] = Map.values(failures[orphan])
    end)
  end
end
