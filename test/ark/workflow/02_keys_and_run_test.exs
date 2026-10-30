defmodule Ark.Workflow.KeysAndRunTest do
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

  defp invalid_target_params do
    port = Port.open({:spawn, "true"}, [])
    [self(), port, make_ref(), fn -> :ok end, &String.upcase/1]
  end

  describe "keys" do
    test "a bare rule name and {name, %{}} are the same key: computed once" do
      {pid, body} = mock_fun(1, ok_body(1))
      wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))

      wf = run!(wf, [:a, {:a, %{}}, {:default, :a, %{}}])

      verify(pid)
      assert {:ok, 1} == Workflow.fetch(wf, :a)
      assert {:ok, 1} == Workflow.fetch(wf, {:a, %{}})
      assert {:ok, 1} == Workflow.fetch(wf, {:default, :a, %{}})
    end

    test ~S(%{user_id: 5} and %{"user_id" => 5} are two keys, each computed once) do
      {pid, body} = mock_fun(2, params_body())
      wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))

      wf =
        run!(wf, [
          {:a, %{user_id: 5}},
          {:a, %{"user_id" => 5}},
          {:a, %{user_id: 5}},
          {:a, %{"user_id" => 5}}
        ])

      verify(pid)
      assert %{user_id: 5} == fetch!(wf, {:a, %{user_id: 5}})
      assert %{"user_id" => 5} == fetch!(wf, {:a, %{"user_id" => 5}})
    end

    test "%{id: 1} and %{id: 1.0} are two keys" do
      {pid, body} = mock_fun(2, params_body())
      wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))

      wf = run!(wf, [{:a, %{id: 1}}, {:a, %{id: 1.0}}])

      verify(pid)
      assert [%{id: 1}, %{id: 1.0}] == Enum.map(calls(pid), &hd/1)
      assert %{id: 1} === fetch!(wf, {:a, %{id: 1}})
      assert %{id: 1.0} === fetch!(wf, {:a, %{id: 1.0}})
    end

    test "params may hold structs and string keys" do
      params = %{
        "name" => "x",
        :struct => %SomeStruct{id: 1, tags: ["a"]},
        "nested" => %{"date" => ~D[2024-01-02], "list" => [%SomeStruct{id: 2}]}
      }

      wf = Workflow.add_rule(Workflow.new(), :a, rule([], params_body()))
      wf = run!(wf, [{:a, params}])

      assert params == fetch!(wf, {:a, params})
    end
  end

  describe "a body receives params exactly as written by the code that demanded the key" do
    test "from a run target" do
      {pid, body} = mock_fun(1, ok_body(1))
      params = %{"id" => 1, :opt => [1, 2.0], :s => %SomeStruct{id: 3}}
      wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))

      _ = run!(wf, [{:a, params}])

      verify(pid)
      assert [[^params, %{}, %{}]] = calls(pid)
    end

    test "from a static dependency" do
      {pid, body} = mock_fun(1, ok_body(1))
      params = %{"id" => 1, :opt => [1, 2.0], :s => %SomeStruct{id: 3}}

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([], body))
        |> Workflow.add_rule(:r, rule([{:a, params}], deps_body()))

      _ = run!(wf, [:r])

      verify(pid)
      assert [[^params, %{}, %{}]] = calls(pid)
    end
  end

  describe "a rule registered without a namespace is in :default" do
    test "a target written name or {name, params} names a rule of :default" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([], params_body()))
        |> Workflow.add_rule({NsA, :a}, const_rule(:ns_a))

      wf = run!(wf, [:a, {:a, %{id: 1}}])

      assert %{} == fetch!(wf, {:default, :a, %{}})
      assert %{id: 1} == fetch!(wf, {:default, :a, %{id: 1}})
      assert :error == Workflow.fetch(wf, {NsA, :a, %{}})
    end

    test "a target {:default, name, params} is the same key" do
      {pid, body} = mock_fun(1, params_body())
      wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))

      wf = run!(wf, [{:default, :a, %{id: 1}}, {:a, %{id: 1}}])

      verify(pid)
      assert %{id: 1} == fetch!(wf, {:a, %{id: 1}})
    end

    test "a target written name does not name a rule of another namespace" do
      wf = Workflow.add_rule(Workflow.new(), {NsA, :a}, const_rule(1))

      for target <- [:a, {:a, %{}}] do
        assert {:error, %GraphError{reason: {:unknown_rule, {:default, :a, %{}}}}, _} =
                 Workflow.run(wf, [target])
      end
    end
  end

  test "an error message prints keys of :default without their namespace" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:top, %{
        alts: [main: %{deps: [{:leaf, %{id: 1}}], body: ok_body(1)}]
      })
      |> Workflow.add_rule(:leaf, %{alts: [main: %{deps: [], body: error_body(:oops)}]})

    assert {:error, %ComputationError{} = e, _} = Workflow.run(wf, [:top])
    message = Exception.message(e)

    assert message =~ ":top"
    assert message =~ "{:leaf, %{id: 1}}"
    refute message =~ "default"

    assert {:error, %GraphError{reason: {:unknown_rule, _}} = e, _} =
             Workflow.run(wf, [:unknown])

    message = Exception.message(e)

    assert message =~ ":unknown"
    refute message =~ "default"
  end

  test "an error message prints keys of other namespaces with their namespace" do
    wf = Workflow.add_rule(Workflow.new(), {NsA, :a}, failing_rule())

    assert {:error, %ComputationError{} = e, _} = Workflow.run(wf, [{NsA, :a, %{}}])
    assert Exception.message(e) =~ inspect(NsA)
  end

  describe "run returns a graph error, without calling user code" do
    setup do
      {pid, never} = mock_never(ok_body(1))
      wf = Workflow.add_rule(Workflow.new(), :first, rule([], never))
      %{pid: pid, wf: wf}
    end

    test "for a target with no registered rule", %{pid: pid, wf: wf} do
      for {target, key} <- [
            {:missing, {:default, :missing, %{}}},
            {{:missing, %{}}, {:default, :missing, %{}}},
            {{NsA, :missing, %{}}, {NsA, :missing, %{}}}
          ] do
        assert {:error, e, wf2} = Workflow.run(wf, [:first, target])
        assert %GraphError{rule: nil, key: nil, reason: {:unknown_rule, ^key}} = e
        assert :error == Workflow.fetch(wf2, :first)
      end

      verify(pid)
    end

    test "for a target with a string ns or name", %{pid: pid, wf: wf} do
      for target <- [
            "first",
            {"first", %{}},
            {"default", :first, %{}},
            {:default, "first", %{}}
          ] do
        assert {:error, %GraphError{rule: nil, reason: {:invalid_key, ^target}}, _} =
                 Workflow.run(wf, [:first, target])
      end

      verify(pid)
    end

    test "for a target with params containing a pid, port, reference or function", %{
      pid: pid,
      wf: wf
    } do
      for bad <- invalid_target_params(),
          target <- [{:first, %{x: bad}}, {:first, %{x: [{bad}]}}] do
        assert {:error, %GraphError{rule: nil, reason: {:invalid_params, ^target}}, _} =
                 Workflow.run(wf, [:first, target])
      end

      verify(pid)
    end

    test "for a malformed target", %{pid: pid, wf: wf} do
      for {target, tag} <- [
            {nil, :invalid_key},
            {true, :invalid_key},
            {1, :invalid_key},
            {{:a, :b, :c, :d}, :invalid_key},
            {{:first, [id: 1]}, :invalid_params},
            {{:default, :first}, :invalid_params}
          ] do
        assert {:error, %GraphError{rule: nil, reason: {^tag, ^target}}, _} =
                 Workflow.run(wf, [:first, target])
      end

      verify(pid)
    end
  end

  describe "run" do
    test "returns {:ok, workflow} when every target has a value, readable by its key" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, const_rule(:va))
        |> Workflow.add_rule(:b, rule([], params_body()))

      assert {:ok, wf} = Workflow.run(wf, [:a, {:b, %{id: 1}}])
      assert {:ok, :va} == Workflow.fetch(wf, :a)
      assert {:ok, %{id: 1}} == Workflow.fetch(wf, {:b, %{id: 1}})
    end

    test "returns {:error, error, workflow} for the first failed target, a computation error naming the target" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, const_rule(:va))
        |> Workflow.add_rule(:b, failing_rule())

      assert {:error, %ComputationError{target: {:default, :b, %{id: 1}}}, wf} =
               Workflow.run(wf, [:a, {:b, %{id: 1}}])

      assert {:ok, :va} == Workflow.fetch(wf, :a)
      assert {:failed, _} = Workflow.fetch(wf, {:b, %{id: 1}})
    end

    test "a second run with the same targets calls no user code" do
      {pid_a, body_a} = mock_fun(1, ok_body(1))
      {pid_b, body_b} = mock_fun(1, error_body())

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([], body_a))
        |> Workflow.add_rule(:b, rule([], body_b))
        |> Workflow.add_rule(:c, rule([:a], deps_body()))

      wf = run!(wf, [:c])
      wf = run!(wf, [:c])
      assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:c, :b])
      assert {:error, %ComputationError{}, _} = Workflow.run(wf, [:c, :b])

      verify(pid_a)
      verify(pid_b)
    end

    test "a second run with other targets reuses the recorded values" do
      {pid, body} = mock_fun(1, ok_body(1))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([], body))
        |> Workflow.add_rule(:b, rule([:a], deps_body()))
        |> Workflow.add_rule(:c, rule([:a], deps_body()))

      wf = run!(wf, [:b])
      wf = run!(wf, [:c])

      verify(pid)
      assert %{a: 1} == fetch!(wf, :c)
    end

    test "with an empty target list returns {:ok, workflow} without calling user code" do
      {pid, never} = mock_never(ok_body(1))
      wf = Workflow.add_rule(Workflow.new(), :a, rule([], never))

      assert {:ok, wf} = Workflow.run(wf, [])
      assert :error == Workflow.fetch(wf, :a)
      verify(pid)
    end

    test "computes a target listed twice once" do
      {pid, body} = mock_fun(1, ok_body(1))
      wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))

      _ = run!(wf, [:a, :a])
      verify(pid)
    end

    test "does not continue the targets of a previous interrupted run" do
      {pid, never} = mock_never(ok_body(1))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, failing_rule())
        |> Workflow.add_rule(:b, rule([], never))
        |> Workflow.add_rule(:c, const_rule(:vc))

      assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a, :b])
      wf = run!(wf, [:c])

      verify(pid)
      assert :error == Workflow.fetch(wf, :b)
    end

    test "rules can be added to a workflow after a run" do
      wf = Workflow.add_rule(Workflow.new(), :a, const_rule(1))
      wf = run!(wf, [:a])

      wf = Workflow.add_rule(wf, :b, rule([:a], deps_body()))
      wf = run!(wf, [:b])

      assert %{a: 1} == fetch!(wf, :b)
    end
  end

  describe "fetch" do
    setup do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:ok, const_rule(:value))
        |> Workflow.add_rule(:failed, failing_rule())
        |> Workflow.add_rule(:other, const_rule(:other))

      {:ok, wf} = Workflow.run(wf, [:ok])
      {:error, %ComputationError{}, wf} = Workflow.run(wf, [:failed])

      %{wf: wf}
    end

    test "returns {:ok, value} for a key with a value", %{wf: wf} do
      assert {:ok, :value} == Workflow.fetch(wf, :ok)
    end

    test "returns {:failed, failure_record} for a failed key", %{wf: wf} do
      assert {:failed, {:all_alternatives_failed, [:default]}} ==
               Workflow.fetch(wf, :failed)
    end

    test "returns :error for a key never demanded", %{wf: wf} do
      assert :error == Workflow.fetch(wf, :other)
      assert :error == Workflow.fetch(wf, {:ok, %{id: 1}})
    end

    test "returns {:error, graph_error} for a key with no registered rule", %{wf: wf} do
      assert {:error,
              %GraphError{rule: nil, reason: {:unknown_rule, {:default, :missing, %{}}}}} =
               Workflow.fetch(wf, :missing)

      assert {:error, %GraphError{reason: {:unknown_rule, {NsA, :ok, %{}}}}} =
               Workflow.fetch(wf, {NsA, :ok, %{}})
    end

    test "returns {:error, graph_error} for an invalid key", %{wf: wf} do
      assert {:error, %GraphError{reason: {:invalid_key, "ok"}}} =
               Workflow.fetch(wf, "ok")

      assert {:error, %GraphError{reason: {:invalid_params, {:ok, [id: 1]}}}} =
               Workflow.fetch(wf, {:ok, [id: 1]})
    end

    test "accepts the key forms of run targets", %{wf: wf} do
      assert {:ok, :value} == Workflow.fetch(wf, :ok)
      assert {:ok, :value} == Workflow.fetch(wf, {:ok, %{}})
      assert {:ok, :value} == Workflow.fetch(wf, {:default, :ok, %{}})
    end
  end

  describe "attempts" do
    test "returns the failure record of each attempted alternative" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, failing_rule())
        |> Workflow.add_rule(:a, %{
          alts: [
            one: %{deps: [], body: error_body(:nope)},
            two: %{deps: [:b], body: ok_body(1)}
          ]
        })

      assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a])

      assert {:ok,
              %{
                one: {:computation_error, %{kind: :user_term, message: ":nope"}},
                two: {:dep_failed, {:default, :b, %{}}}
              }} = Workflow.attempts(wf, :a)
    end

    test "returns an empty map for a key with no attempts" do
      wf = Workflow.add_rule(Workflow.new(), :a, const_rule(1))
      assert {:ok, %{}} == Workflow.attempts(wf, :a)

      wf = run!(wf, [:a])
      assert {:ok, %{}} == Workflow.attempts(wf, :a)
    end

    test "returns a graph error for a key with no registered rule" do
      assert {:error, %GraphError{reason: {:unknown_rule, {:default, :a, %{}}}}} =
               Workflow.attempts(Workflow.new(), :a)
    end
  end
end
