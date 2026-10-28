defmodule Ark.Workflow.DumpLoadTest do
  use ExUnit.Case, async: true

  import Ark.Test.Mock
  import Ark.Test.WorkflowHelpers
  import ExUnit.CaptureLog

  alias Ark.Workflow
  alias Ark.Workflow.CodecError
  alias Ark.Workflow.ComputationError
  alias Ark.Workflow.GraphError

  defmodule NsA do
  end

  defmodule SomeStruct do
    defstruct [:id, :data]
  end

  def tuple_dump(value, extra) do
    %{"dumped" => inspect({value, extra})}
  end

  def tuple_load(%{"dumped" => s}, extra) do
    {:loaded, s, extra}
  end

  defp key(name, params) do
    {:default, name, params}
  end

  defp json(data) do
    data |> JSON.encode!() |> JSON.decode!()
  end

  defp dump!(wf) do
    assert {:ok, data} = Workflow.dump(wf)
    data
  end

  defp warnings(log) do
    length(Regex.scan(~r/\[warning\]/, log))
  end

  defp sample_terms do
    [
      "string",
      "",
      42,
      -1.5,
      true,
      false,
      nil,
      [1, "two", nil],
      %{"a" => [1, %{"b" => 2}]},
      :atom,
      %{atom_key: 1},
      {:tuple, 1, "x"},
      %SomeStruct{id: 1, data: [:a]},
      ~D[2024-01-02],
      ~U[2024-01-02 03:04:05.123456Z],
      <<0xFF, 0xFE, 0>>,
      <<1::3>>,
      [1 | 2],
      [1, 2 | :tail],
      %{1 => "integer key", {:t} => "tuple key"},
      %{"mixed" => %{atom: [{1, 2.5}]}}
    ]
  end

  describe "dump" do
    test "produces data that encodes to JSON, and loading the decoded JSON restores the state" do
      {pid, body} = mock_fun(1, params_body())
      {cpid, consumer_body} = mock_fun(1, deps_body())

      graph = fn ->
        Workflow.new()
        |> Workflow.add_rule(:a, rule([], body))
        |> Workflow.add_rule(:c, rule([{:a, %{id: 1}}], consumer_body))
      end

      wf = run!(graph.(), [:c])

      data = dump!(wf)
      assert is_binary(JSON.encode!(data))

      wf2 = roundtrip(wf, graph.())
      wf2 = run!(wf2, [:c])

      verify(pid)
      verify(cpid)
      assert fetch!(wf, :c) == fetch!(wf2, :c)
      assert %{id: 1} == fetch!(wf2, {:a, %{id: 1}})
    end

    test "does not change the workflow: it can still be run" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, const_rule(1))
        |> Workflow.add_rule(:b, rule([:a], deps_body()))

      wf = run!(wf, [:a])
      _ = dump!(wf)
      wf = run!(wf, [:b])

      assert %{a: 1} == fetch!(wf, :b)
    end

    test "of an empty workflow loads into an empty workflow" do
      wf = Workflow.add_rule(Workflow.new(), :a, const_rule(1))
      wf2 = roundtrip(wf, wf)
      assert :error == Workflow.fetch(wf2, :a)
    end
  end

  describe "a loaded workflow" do
    test "can be run, and rules can still be added to it" do
      {pid, body} = mock_fun(1, ok_body(1))
      graph = fn -> Workflow.add_rule(Workflow.new(), :a, rule([], body)) end

      wf = run!(graph.(), [:a])
      wf = roundtrip(wf, graph.())

      wf = Workflow.add_rule(wf, :b, rule([:a], deps_body()))
      wf = run!(wf, [:b])

      verify(pid)
      assert %{a: 1} == fetch!(wf, :b)
    end
  end

  describe "terms survive the round trip as equal terms" do
    test "in params and in values" do
      {pid, body} =
        mock_fun(length(sample_terms()), fn %{term: t}, _, _ -> {:ok, {:value, t}} end)

      graph = fn -> Workflow.add_rule(Workflow.new(), :a, rule([], body)) end
      targets = Enum.map(sample_terms(), &{:a, %{term: &1}})

      wf = run!(graph.(), targets)
      wf = roundtrip(wf, graph.())
      wf = run!(wf, targets)

      verify(pid)

      for term <- sample_terms() do
        assert {:value, term} === fetch!(wf, {:a, %{term: term}})
      end
    end

    test "as whole params and values" do
      json_params = %{"s" => "x", "n" => [1, 2.5, nil, true], "m" => %{"k" => "v"}}
      etf_params = %{atom: :key, struct: %SomeStruct{id: 1}, date: ~D[2024-01-01]}
      {pid, body} = mock_fun(2, params_body())
      graph = fn -> Workflow.add_rule(Workflow.new(), :a, rule([], body)) end

      wf = run!(graph.(), [{:a, json_params}, {:a, etf_params}])
      wf = roundtrip(wf, graph.())
      wf = run!(wf, [{:a, json_params}, {:a, etf_params}])

      verify(pid)
      assert json_params === fetch!(wf, {:a, json_params})
      assert etf_params === fetch!(wf, {:a, etf_params})
    end
  end

  test ~S(%{user_id: 5} and %{"user_id" => 5} are still two keys after a round trip) do
    {pid, body} = mock_fun(2, params_body())
    graph = fn -> Workflow.add_rule(Workflow.new(), :a, rule([], body)) end
    targets = [{:a, %{user_id: 5}}, {:a, %{"user_id" => 5}}]

    wf = run!(graph.(), targets)
    wf = roundtrip(wf, graph.())
    wf = run!(wf, targets)

    verify(pid)
    assert %{user_id: 5} === fetch!(wf, {:a, %{user_id: 5}})
    assert %{"user_id" => 5} === fetch!(wf, {:a, %{"user_id" => 5}})
  end

  test ~S(%{"id" => 1} and %{"id" => 1.0} are still two keys after a round trip through JSON) do
    {pid, body} = mock_fun(2, params_body())
    graph = fn -> Workflow.add_rule(Workflow.new(), :a, rule([], body)) end
    targets = [{:a, %{"id" => 1}}, {:a, %{"id" => 1.0}}]

    wf = run!(graph.(), targets)
    wf = roundtrip(wf, graph.())
    wf = run!(wf, targets)

    verify(pid)
    assert %{"id" => 1} === fetch!(wf, {:a, %{"id" => 1}})
    assert %{"id" => 1.0} === fetch!(wf, {:a, %{"id" => 1.0}})
  end

  test "a body receives params after a dump and a load identical to an uninterrupted run" do
    params = %{"id" => 1, :opt => [1, 2.0], :s => %SomeStruct{id: 3}}
    {pid, body} = mock_fun(1, ok_body(1))

    graph = fn broken ->
      Workflow.new()
      |> Workflow.add_rule(:a, %{
        alts: [
          first: %{deps: [], body: error_body()},
          second: %{deps: [:broken], body: body}
        ]
      })
      |> Workflow.add_rule(:broken, broken)
    end

    broken = rule([fn _, _, _ -> "invalid" end], ok_body(1))
    {:error, %GraphError{}, wf} = Workflow.run(graph.(broken), [{:a, params}])
    assert {:ok, %{first: _}} = Workflow.attempts(wf, {:a, params})

    wf = roundtrip(wf, graph.(const_rule(:fixed)))
    wf = run!(wf, [{:a, params}])

    verify(pid)
    assert [[received, %{broken: :fixed}, %{}]] = calls(pid)
    assert params === received
    assert 1 == fetch!(wf, {:a, params})
  end

  test "dumping a loaded state that was not run produces the same data as the original dump, including orphaned records" do
    graph =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([:b], ok_body(1)))
      |> Workflow.add_rule(:b, failing_rule())
      |> Workflow.add_rule(:c, %{
        alts: [
          one: %{deps: [], body: error_body()},
          two: %{deps: [], body: params_body()}
        ]
      })
      |> Workflow.add_rule({NsA, :removed}, const_rule(%{"json" => true}))

    {:error, %ComputationError{}, wf} =
      Workflow.run(graph, [{NsA, :removed, %{}}, {:c, %{id: 1}}, :a])

    data = json(dump!(wf))

    assert data == json(dump!(Workflow.load(graph, data) |> elem(1)))

    reduced = Workflow.add_rule(Workflow.new(), :c, const_rule(:other))

    capture_log(fn ->
      assert {:ok, loaded} = Workflow.load(reduced, data)
      assert data == json(dump!(loaded))
    end)
  end

  test "a failure record queried after a round trip equals the one before, including its time, kind and message, apart from the reason of its cleaned error" do
    graph =
      Workflow.new()
      |> Workflow.add_rule(:a, %{
        alts: [
          user_term: %{deps: [], body: error_body(:x)},
          bad_return: %{deps: [], body: fn _, _, _ -> :not_ok end},
          error: %{deps: [], body: fn _, _, _ -> raise "boom" end},
          throw: %{deps: [], body: fn _, _, _ -> throw(:thrown) end},
          exit: %{deps: [], body: fn _, _, _ -> exit(:exited) end},
          dep: %{deps: [{:b, %{id: 1}}], body: ok_body(1)}
        ]
      })
      |> Workflow.add_rule(:b, failing_rule())

    {:error, %ComputationError{}, wf} = Workflow.run(graph, [:a])
    loaded = roundtrip(wf, graph)

    assert without_reasons(Workflow.attempts(wf, :a)) == Workflow.attempts(loaded, :a)
    assert Workflow.fetch(wf, :a) == Workflow.fetch(loaded, :a)

    assert without_reasons(Workflow.attempts(wf, {:b, %{id: 1}})) ==
             Workflow.attempts(loaded, {:b, %{id: 1}})
  end

  test "the computation error for a target that failed before a dump and a load is the same as the one returned by the run that failed it, apart from the reason of its causes" do
    graph =
      Workflow.new()
      |> Workflow.add_rule(:a, %{
        alts: [
          one: %{deps: [:b], body: ok_body(1)},
          two: %{deps: [], body: fn _, _, _ -> raise "boom" end}
        ]
      })
      |> Workflow.add_rule(:b, failing_rule(%{reason: "x"}))

    {:error, %ComputationError{} = e1, wf} = Workflow.run(graph, [:a])
    {:error, %ComputationError{} = e2, _} = Workflow.run(roundtrip(wf, graph), [:a])

    assert without_reasons(e1) == e2
    assert Exception.message(e1) == Exception.message(e2)
  end

  test "the reason of a cleaned error is nil after a dump and a load, while its message, kind and time are unchanged" do
    graph =
      Workflow.add_rule(Workflow.new(), :a, %{
        alts: [
          user_term: %{deps: [], body: error_body(:x)},
          bad_return: %{deps: [], body: fn _, _, _ -> :not_ok end},
          error: %{deps: [], body: fn _, _, _ -> raise "boom" end},
          throw: %{deps: [], body: fn _, _, _ -> throw(:thrown) end},
          exit: %{deps: [], body: fn _, _, _ -> exit(:exited) end}
        ]
      })

    {:error, %ComputationError{}, wf} = Workflow.run(graph, [:a])
    loaded = roundtrip(wf, graph)

    assert {:ok, before} = Workflow.attempts(wf, :a)
    assert {:ok, after_load} = Workflow.attempts(loaded, :a)
    assert 5 == map_size(before)

    for {alt, {:computation_error, cleaned}} <- before do
      assert cleaned.reason != nil

      assert {:computation_error, %{reason: nil} = loaded_cleaned} =
               Map.fetch!(after_load, alt)

      assert Map.take(cleaned, [:at, :kind, :message]) ==
               Map.take(loaded_cleaned, [:at, :kind, :message])
    end

    assert {:error, %ComputationError{causes: causes}, _} = Workflow.run(loaded, [:a])
    assert [nil, nil, nil, nil, nil] == Enum.map(causes, & &1.error.reason)
  end

  test "a cleaned error whose reason holds a pid or a function does not make dump fail" do
    fun = fn -> :x end

    graph =
      Workflow.add_rule(Workflow.new(), :a, %{
        alts: [
          pid: %{deps: [], body: error_body({:down, self()})},
          fun: %{deps: [], body: fn _, _, _ -> throw(fun) end}
        ]
      })

    {:error, %ComputationError{}, wf} = Workflow.run(graph, [:a])

    assert {:ok,
            %{
              pid: {:computation_error, %{reason: {:down, _}}},
              fun: {:computation_error, %{reason: ^fun}}
            }} =
             Workflow.attempts(wf, :a)

    assert {:ok, _} = Workflow.dump(wf)
    loaded = roundtrip(wf, graph)

    assert {:ok,
            %{
              pid: {:computation_error, %{kind: :user_term, reason: nil}},
              fun: {:computation_error, %{kind: :throw, reason: nil}}
            }} = Workflow.attempts(loaded, :a)
  end

  test "a {:dep_failed, key} record pointing to an orphaned key survives a load and a dump" do
    graph =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([{:b, %{id: 1}}], ok_body(1)))
      |> Workflow.add_rule(:b, failing_rule())

    {:error, %ComputationError{}, wf} = Workflow.run(graph, [:a])
    data = json(dump!(wf))

    reduced = Workflow.add_rule(Workflow.new(), :a, rule([], ok_body(1)))

    capture_log(fn ->
      assert {:ok, loaded} = Workflow.load(reduced, data)

      assert {:ok, %{default: {:dep_failed, key(:b, %{id: 1})}}} ==
               Workflow.attempts(loaded, :a)

      assert data == json(dump!(loaded))

      assert {:ok, reloaded} = Workflow.load(graph, data)
      assert {:failed, _} = Workflow.fetch(reloaded, {:b, %{id: 1}})
    end)
  end

  describe "a value containing a pid, port, reference or function" do
    test "makes dump return a codec error naming the key" do
      port = Port.open({:spawn, "true"}, [])

      for bad <- [self(), port, make_ref(), fn -> 1 end, %{"nested" => [{:ok, self()}]}] do
        wf = Workflow.add_rule(Workflow.new(), :a, const_rule(bad))
        wf = run!(wf, [{:a, %{id: 1}}])

        assert {:error, %CodecError{} = e} = Workflow.dump(wf)
        assert key(:a, %{id: 1}) == e.key
        assert Exception.message(e) =~ "{:a, %{id: 1}}"
      end
    end

    test "dumps fine when the rule's :dump turns it into data" do
      pid = self()

      graph =
        Workflow.add_rule(Workflow.new(), :a, %{
          alts: [default: %{deps: [], body: ok_body(%{pid: pid, n: 1})}],
          dump: fn %{n: n} -> %{"n" => n} end,
          load: fn %{"n" => n} -> %{pid: nil, n: n} end
        })

      wf = run!(graph, [:a])
      wf = roundtrip(wf, graph)

      assert %{pid: nil, n: 1} == fetch!(wf, :a)
    end
  end

  test "a rule's :dump that raises, or returns a pid, makes dump return a codec error naming the key" do
    for dump_fun <- [fn _ -> raise "cannot dump" end, fn _ -> self() end] do
      graph =
        Workflow.add_rule(Workflow.new(), :a, %{
          alts: [default: %{deps: [], body: ok_body(1)}],
          dump: dump_fun
        })

      wf = run!(graph, [{:a, %{id: 2}}])

      assert {:error, %CodecError{} = e} = Workflow.dump(wf)
      assert key(:a, %{id: 2}) == e.key
    end
  end

  describe "a rule's :dump and :load" do
    test "are identity when not declared" do
      {pid, body} =
        mock_fun(length(sample_terms()), fn %{i: i}, _, _ ->
          {:ok, Enum.at(sample_terms(), i)}
        end)

      graph = Workflow.add_rule(Workflow.new(), :a, rule([], body))
      targets = Enum.map(0..(length(sample_terms()) - 1), &{:a, %{i: &1}})

      wf = run!(graph, targets)
      wf = roundtrip(wf, graph)

      verify(pid)

      for {term, i} <- Enum.with_index(sample_terms()) do
        assert term === fetch!(wf, {:a, %{i: i}})
      end
    end

    test "are applied to the rule's values: a consumer after a resume receives load(dump(value))" do
      {dump_pid, dump_fun} = mock_fun(1, fn v -> %{"v" => v} end)
      {load_pid, load_fun} = mock_fun(1, fn %{"v" => v} -> {:loaded, v} end)

      graph =
        Workflow.new()
        |> Workflow.add_rule(:user, %{
          alts: [default: %{deps: [], body: ok_body("u1")}],
          dump: dump_fun,
          load: load_fun
        })
        |> Workflow.add_rule(:consumer, rule([:user], deps_body()))

      wf = run!(graph, [:user])
      assert "u1" == fetch!(wf, :user)

      wf = roundtrip(wf, graph)
      wf = run!(wf, [:consumer])

      verify(dump_pid)
      verify(load_pid)
      assert %{user: {:loaded, "u1"}} == fetch!(wf, :consumer)
      assert {:loaded, "u1"} == fetch!(wf, :user)
    end

    test "apply to every alternative of the rule" do
      graph =
        Workflow.add_rule(Workflow.new(), :r, %{
          alts: [
            first: %{
              deps: [],
              body: fn %{n: n}, _, _ ->
                if n == 1 do
                  {:ok, :first}
                else
                  {:error, :x}
                end
              end
            },
            second: %{deps: [], body: ok_body(:second)}
          ],
          dump: fn v -> %{"v" => Atom.to_string(v)} end,
          load: fn %{"v" => v} -> {:loaded, v} end
        })

      wf = run!(graph, [{:r, %{n: 1}}, {:r, %{n: 2}}])
      wf = roundtrip(wf, graph)

      assert {:loaded, "first"} == fetch!(wf, {:r, %{n: 1}})
      assert {:loaded, "second"} == fetch!(wf, {:r, %{n: 2}})
    end

    test "given as tuples are called with the value, or the data, before extra_args" do
      graph =
        Workflow.add_rule(Workflow.new(), :a, %{
          alts: [default: %{deps: [], body: ok_body(:v)}],
          dump: {__MODULE__, :tuple_dump, [:dump_extra]},
          load: {__MODULE__, :tuple_load, [:load_extra]}
        })

      wf = run!(graph, [:a])
      wf = roundtrip(wf, graph)

      assert {:loaded, inspect({:v, :dump_extra}), :load_extra} == fetch!(wf, :a)
    end

    test "are not applied to failure records" do
      {pid, fun} = mock_fun(0, & &1)

      graph =
        Workflow.add_rule(Workflow.new(), :a, %{
          alts: [default: %{deps: [], body: error_body(:x)}],
          dump: fun,
          load: fun
        })

      {:error, %ComputationError{}, wf} = Workflow.run(graph, [:a])
      loaded = roundtrip(wf, graph)

      verify(pid)
      assert Workflow.fetch(wf, :a) == Workflow.fetch(loaded, :a)
      assert without_reasons(Workflow.attempts(wf, :a)) == Workflow.attempts(loaded, :a)
    end
  end

  test "load returns a codec error for a malformed dump" do
    wf = Workflow.add_rule(Workflow.new(), :a, const_rule(1))

    for data <- ["garbage", 123, nil, true] do
      assert {:error, %CodecError{}} = Workflow.load(wf, data)
    end
  end

  test "a value whose rule's :load fails makes load, or the run that first uses the value, return a codec error, never turning the key into a failure" do
    graph = fn load_fun ->
      Workflow.new()
      |> Workflow.add_rule(:a, %{
        alts: [default: %{deps: [], body: ok_body(1)}],
        load: load_fun
      })
      |> Workflow.add_rule(:b, rule([:a], deps_body()))
    end

    wf = run!(graph.(& &1), [:a])
    data = json(dump!(wf))

    case Workflow.load(graph.(fn _ -> raise "incompatible" end), data) do
      {:error, %CodecError{}} ->
        :ok

      {:ok, loaded} ->
        assert {:error, %CodecError{}, loaded} = Workflow.run(loaded, [:b])
        refute match?({:failed, _}, Workflow.fetch(loaded, :a))
        refute match?({:failed, _}, Workflow.fetch(loaded, :b))
    end
  end

  describe "records of a rule removed from the code" do
    setup do
      {pid, body} = mock_fun(1, ok_body(:computed_before))

      full = fn ->
        Workflow.new()
        |> Workflow.add_rule(:kept, const_rule(:kept))
        |> Workflow.add_rule(:removed_rule, rule([], body))
        |> Workflow.add_rule({NsA, :other_removed}, failing_rule())
      end

      {:error, %ComputationError{}, wf} =
        Workflow.run(full.(), [:kept, :removed_rule, {NsA, :other_removed, %{id: 1}}])

      data = json(dump!(wf))
      reduced = Workflow.add_rule(Workflow.new(), :kept, const_rule(:kept))

      %{data: data, full: full, reduced: reduced, pid: pid}
    end

    test "are loaded and kept as orphaned records, written back by dump", %{
      data: data,
      reduced: reduced
    } do
      capture_log(fn ->
        assert {:ok, loaded} = Workflow.load(reduced, data)
        assert {:ok, :kept} == Workflow.fetch(loaded, :kept)
        assert data == json(dump!(loaded))
      end)
    end

    test "make load emit one warning listing the rules they belong to", %{
      data: data,
      reduced: reduced
    } do
      log = capture_log(fn -> assert {:ok, _} = Workflow.load(reduced, data) end)

      assert 1 == warnings(log)
      assert log =~ "removed_rule"
      assert log =~ "other_removed"
    end

    test "make load emit no warning when every record has a rule", %{
      data: data,
      full: full
    } do
      log = capture_log(fn -> assert {:ok, _} = Workflow.load(full.(), data) end)
      assert 0 == warnings(log)
    end

    test "take no part in evaluation: demanding that key is a graph error", %{
      data: data,
      reduced: reduced
    } do
      capture_log(fn ->
        {:ok, loaded} = Workflow.load(reduced, data)

        assert {:error, %GraphError{}, _} = Workflow.run(loaded, [:removed_rule])
        assert {:error, %GraphError{}} = Workflow.fetch(loaded, :removed_rule)

        assert {:error, %GraphError{}} =
                 Workflow.attempts(loaded, {NsA, :other_removed, %{id: 1}})

        loaded =
          Workflow.add_rule(
            loaded,
            :consumer,
            rule([fn _, _, _ -> :removed_rule end], ok_body(1))
          )

        assert {:error, %GraphError{kind: :unknown_rule}, _} =
                 Workflow.run(loaded, [:consumer])
      end)
    end

    test "are found again when the rule is registered again under the same identity, before the load",
         %{data: data, full: full, pid: pid} do
      log =
        capture_log(fn ->
          assert {:ok, loaded} = Workflow.load(full.(), data)
          loaded = run!(loaded, [:removed_rule])
          assert :computed_before == fetch!(loaded, :removed_rule)
          assert {:failed, _} = Workflow.fetch(loaded, {NsA, :other_removed, %{id: 1}})
        end)

      verify(pid)
      assert 0 == warnings(log)
    end

    test "stay orphaned when the rule is added to the workflow after the load: its keys are computed again, and dump writes the computed entries over the orphaned ones, with a warning naming the keys",
         %{data: data, reduced: reduced, full: full} do
      capture_log(fn ->
        {:ok, loaded} = Workflow.load(reduced, data)
        loaded = Workflow.add_rule(loaded, :removed_rule, const_rule(:computed_after))

        loaded = run!(loaded, [:removed_rule])
        assert :computed_after == fetch!(loaded, :removed_rule)

        log = capture_log(fn -> send(self(), {:data, dump!(loaded)}) end)
        assert_received {:data, new_data}

        assert log =~ ":removed_rule"
        refute log =~ "other_removed"

        {:ok, reloaded} = Workflow.load(full.(), json(new_data))
        assert :computed_after == fetch!(reloaded, :removed_rule)
        assert {:failed, _} = Workflow.fetch(reloaded, {NsA, :other_removed, %{id: 1}})
      end)
    end
  end

  describe "dependency functions after a resume" do
    test "are not called once the key has a value" do
      {pid, deps_fun} = mock_fun(100, fn _, _, _ -> :a end)

      graph =
        Workflow.new()
        |> Workflow.add_rule(:a, const_rule(1))
        |> Workflow.add_rule(:r, rule([deps_fun], deps_body()))
        |> Workflow.add_rule(:consumer, rule([:r], deps_body()))

      wf = run!(graph, [:r])
      count = length(calls(pid))

      wf = roundtrip(wf, graph)
      wf = run!(wf, [:consumer])

      assert count == length(calls(pid))
      assert %{r: %{a: 1}} == fetch!(wf, :consumer)
    end

    test "are called again with the loaded values" do
      {pid, deps_fun} = mock_fun(100, fn _, %{a: a}, _ -> {:b, %{a: a}} end)

      graph = fn broken_rule ->
        Workflow.new()
        |> Workflow.add_rule(:a, %{
          alts: [default: %{deps: [], body: ok_body(%{id: 1})}],
          dump: fn %{id: id} -> %{"id" => id} end,
          load: fn %{"id" => id} -> %{id: id, loaded: true} end
        })
        |> Workflow.add_rule(:b, rule([], params_body()))
        |> Workflow.add_rule(:broken, broken_rule)
        |> Workflow.add_rule(:r, rule([:a, :broken, deps_fun], deps_body()))
      end

      broken = rule([fn _, _, _ -> "invalid" end], ok_body(1))
      {:error, %GraphError{}, wf} = Workflow.run(graph.(broken), [:r])
      assert [] == calls(pid)

      wf = roundtrip(wf, graph.(const_rule(:fixed)))
      wf = run!(wf, [:r])

      loaded_a = %{id: 1, loaded: true}
      assert [[%{}, %{a: ^loaded_a, broken: :fixed}, %{}] | _] = calls(pid)

      assert %{:a => loaded_a, :broken => :fixed, {:b, %{a: loaded_a}} => %{a: loaded_a}} ==
               fetch!(wf, :r)
    end
  end

  test "after a graph error from a dependency function, a run with fixed code continues without calling the user code of recorded keys again" do
    {a_pid, a_body} = mock_fun(1, ok_body(:va))
    {f_pid, first_body} = mock_fun(1, error_body())

    graph = fn deps_fun ->
      Workflow.new()
      |> Workflow.add_rule(:a, rule([], a_body))
      |> Workflow.add_rule(:b, const_rule(:vb))
      |> Workflow.add_rule(:r, %{
        alts: [
          first: %{deps: [], body: first_body},
          second: %{deps: [:a, deps_fun], body: deps_body()}
        ]
      })
    end

    {:error, %GraphError{}, wf} = Workflow.run(graph.(fn _, _, _ -> "invalid" end), [:r])

    wf = roundtrip(wf, graph.(fn _, _, _ -> :b end))
    wf = run!(wf, [:r])

    verify(a_pid)
    verify(f_pid)
    assert %{a: :va, b: :vb} == fetch!(wf, :r)
  end

  test "a dependency function returning a key with no registered rule is a graph error even when the state holds records for that key" do
    full =
      Workflow.new()
      |> Workflow.add_rule(:gone, const_rule(1))
      |> Workflow.add_rule(:r, rule([fn _, _, _ -> :gone end], deps_body()))

    wf = run!(full, [:gone])

    reduced =
      Workflow.add_rule(Workflow.new(), :r, rule([fn _, _, _ -> :gone end], deps_body()))

    capture_log(fn ->
      wf = roundtrip(wf, reduced)
      assert {:error, %GraphError{kind: :unknown_rule}, _} = Workflow.run(wf, [:r])
    end)
  end

  test "context is not persisted: after a load, user code sees only the context given to the run" do
    {pid, body} = mock_fun(1, ok_body(1))

    graph =
      Workflow.new()
      |> Workflow.add_rule(:a, const_rule(1))
      |> Workflow.add_rule(:b, rule([], body))

    wf = run!(graph, [:a], context: %{secret: 1})
    wf = roundtrip(wf, graph)
    _ = run!(wf, [:b], context: %{other: 2})

    verify(pid)
    assert [[%{}, %{}, %{other: 2}]] == calls(pid)
  end

  describe "dump check" do
    test "with the dump check enabled, dump emits a single warning listing every key whose :dump output is stored as ETF" do
      wf =
        Workflow.new(dump_check: true)
        |> Workflow.add_rule(:etf_value_one, const_rule(%{atom_key: 1}))
        |> Workflow.add_rule(:etf_value_two, const_rule({:tuple}))
        |> Workflow.add_rule(:json_value, const_rule(%{"k" => [1, "x", nil]}))
        |> Workflow.add_rule(:etf_dumped_as_json, %{
          alts: [default: %{deps: [], body: ok_body(%{atom_key: 1})}],
          dump: fn %{atom_key: v} -> %{"atom_key" => v} end,
          load: fn %{"atom_key" => v} -> %{atom_key: v} end
        })

      wf =
        run!(wf, [
          :etf_value_one,
          {:etf_value_two, %{id: 1}},
          :json_value,
          :etf_dumped_as_json
        ])

      log = capture_log(fn -> assert {:ok, _} = Workflow.dump(wf) end)

      assert 1 == warnings(log)
      assert log =~ "etf_value_one"
      assert log =~ "{:etf_value_two, %{id: 1}}"
      refute log =~ "json_value"
      refute log =~ "etf_dumped_as_json"
    end

    test "with the dump check enabled and only JSON-native values, dump emits no warning" do
      wf =
        Workflow.new(dump_check: true)
        |> Workflow.add_rule(:a, const_rule(%{"k" => [1, 2.5, "x", nil, true]}))
        |> Workflow.add_rule(:b, failing_rule())

      wf = run!(wf, [{:a, %{atom: :params}}])
      {:error, _, wf} = Workflow.run(wf, [:b])

      log = capture_log(fn -> assert {:ok, _} = Workflow.dump(wf) end)
      assert 0 == warnings(log)
    end

    test "with the dump check disabled, dump emits no warning" do
      for wf <- [Workflow.new(), Workflow.new(dump_check: false)] do
        wf = wf |> Workflow.add_rule(:a, const_rule(%{atom_key: 1})) |> run!([:a])

        log = capture_log(fn -> assert {:ok, _} = Workflow.dump(wf) end)
        assert 0 == warnings(log)
      end
    end
  end
end
