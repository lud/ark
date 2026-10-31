defmodule Ark.Workflow.ComputationErrorTest do
  use ExUnit.Case, async: true

  import Ark.Test.WorkflowHelpers

  alias Ark.Workflow
  alias Ark.Workflow.ComputationError
  alias Ark.Workflow.GraphError

  defmodule NsA do
  end

  defp key(name, params \\ %{}) do
    {:default, name, params}
  end

  defmodule SomeError do
    defexception [:code]

    @impl true
    def message(e) do
      "some error #{e.code}"
    end
  end

  defp walk_to_leaf(wf, key) do
    assert {:failed, {:all_alternatives_failed, [alt]}} = Workflow.fetch(wf, key)

    case Workflow.attempts(wf, key) do
      {:ok, %{^alt => {:dep_failed, dep_key}}} -> walk_to_leaf(wf, dep_key)
      {:ok, %{^alt => {:computation_error, cleaned}}} -> [key, alt, cleaned]
    end
  end

  defp run_failed(wf, targets) do
    assert {:error, %ComputationError{} = e, wf} = Workflow.run(wf, targets)
    {e, wf}
  end

  defp failures!(wf, key) do
    assert {:ok, failures} = Workflow.failures(wf, key)
    failures
  end

  describe "when :a needs :b, :b needs :c and :c fails" do
    setup do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([:b], ok_body(1)))
        |> Workflow.add_rule(:b, rule([{:c, %{id: 1}}], ok_body(1)))
        |> Workflow.add_rule(:c, failing_rule(:leaf_reason))

      %{wf: wf}
    end

    test "the failure of :a points to :b only", %{wf: wf} do
      {_, wf} = run_failed(wf, [:a])
      assert {:ok, %{default: {:dep_failed, key(:b)}}} == Workflow.attempts(wf, :a)
    end

    @tag :skip
    test "the failures of target :a hold the records of :a, :b and :c, each pointing one level down, and the error of :c as the root cause",
         %{wf: wf} do
      {e, wf} = run_failed(wf, [:a])

      assert key(:a) == e.target

      assert %{
               key(:a) => %{default: {:dep_failed, key(:b)}},
               key(:b) => %{default: {:dep_failed, key(:c, %{id: 1})}},
               key(:c, %{id: 1}) => %{default: {:computation_error, :leaf_reason}}
             } == outline(failures!(wf, e.target))

      c = key(:c, %{id: 1})

      assert %{
               ^c => %{
                 default:
                   {:computation_error, %{kind: :user_term, message: ":leaf_reason"}}
               }
             } =
               failures!(wf, e.target)
    end
  end

  test "the message of a computation error names its target" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([:b], ok_body(1)))
      |> Workflow.add_rule(:b, failing_rule())

    {e, _} = run_failed(wf, [{:a, %{id: 7}}])
    assert Exception.message(e) =~ "{:a, %{id: 7}}"
  end

  @tag :skip
  test "the failures of a target whose alternatives failed on different branches hold every failed key reachable from it, with all its attempt records" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, %{
        alts: [
          a1: %{deps: [:b], body: ok_body(1)},
          a2: %{deps: [], body: error_body(:a_reason)},
          a3: %{deps: [:mid], body: ok_body(1)}
        ]
      })
      |> Workflow.add_rule(:b, failing_rule(:b_reason))
      |> Workflow.add_rule(:mid, %{
        alts: [
          mid1: %{deps: [:c], body: ok_body(1)},
          mid2: %{deps: [], body: fn _, _, _ -> raise "mid raise" end}
        ]
      })
      |> Workflow.add_rule(:c, failing_rule(:c_reason))

    {e, wf} = run_failed(wf, [:a])

    assert %{
             key(:a) => %{
               a1: {:dep_failed, key(:b)},
               a2: {:computation_error, :a_reason},
               a3: {:dep_failed, key(:mid)}
             },
             key(:b) => %{default: {:computation_error, :b_reason}},
             key(:mid) => %{
               mid1: {:dep_failed, key(:c)},
               mid2: {:computation_error, %RuntimeError{message: "mid raise"}}
             },
             key(:c) => %{default: {:computation_error, :c_reason}}
           } == outline(failures!(wf, e.target))
  end

  @tag :skip
  test "the failures of a target hold a key reached through several records once" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, %{
        alts: [
          a1: %{deps: [:b], body: ok_body(1)},
          a2: %{deps: [:c], body: ok_body(1)}
        ]
      })
      |> Workflow.add_rule(:c, rule([:b], ok_body(1)))
      |> Workflow.add_rule(:b, failing_rule(:b_reason))

    {e, wf} = run_failed(wf, [:a])

    assert %{
             key(:a) => %{a1: {:dep_failed, key(:b)}, a2: {:dep_failed, key(:c)}},
             key(:c) => %{default: {:dep_failed, key(:b)}},
             key(:b) => %{default: {:computation_error, :b_reason}}
           } == outline(failures!(wf, e.target))
  end

  @tag :skip
  test "the failures of a key hold only the failed keys reachable from it" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([:b], ok_body(1)))
      |> Workflow.add_rule(:b, failing_rule(:b_reason))
      |> Workflow.add_rule(:other, failing_rule(:other_reason))

    {_, wf} = run_failed(wf, [:other])
    {_, wf} = run_failed(wf, [:a])

    assert %{
             key(:a) => %{default: {:dep_failed, key(:b)}},
             key(:b) => %{default: {:computation_error, :b_reason}}
           } == outline(failures!(wf, :a))

    assert %{key(:b) => %{default: {:computation_error, :b_reason}}} ==
             outline(failures!(wf, :b))
  end

  @tag :skip
  test "the failures of a key do not hold a dependency with a value, even when some of its alternatives failed" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([:b], error_body(:a_reason)))
      |> Workflow.add_rule(:b, %{
        alts: [
          b1: %{deps: [], body: error_body(:b_reason)},
          b2: %{deps: [], body: ok_body(1)}
        ]
      })

    {_, wf} = run_failed(wf, [:a])

    assert %{key(:a) => %{default: {:computation_error, :a_reason}}} ==
             outline(failures!(wf, :a))
  end

  @tag :skip
  test "the failures of a key hold the cleaned error of each root cause, with its kind, message, time and reason" do
    wf =
      Workflow.add_rule(Workflow.new(), :a, %{
        alts: [
          user_term: %{deps: [], body: error_body(:x)},
          bad_return: %{deps: [], body: fn _, _, _ -> :not_ok end},
          error: %{deps: [], body: fn _, _, _ -> raise "boom" end},
          throw: %{deps: [], body: fn _, _, _ -> throw(:thrown) end},
          exit: %{deps: [], body: fn _, _, _ -> exit(:exited) end}
        ]
      })

    {e, wf} = run_failed(wf, [:a])
    a = key(:a)
    assert %{^a => alts} = failures!(wf, e.target)

    assert [:bad_return, :error, :exit, :throw, :user_term] ==
             alts |> Map.keys() |> Enum.sort()

    for {alt, {:computation_error, error}} <- alts do
      assert %{kind: ^alt, message: message, at: %DateTime{}} = error
      assert is_binary(message)
    end

    assert %{
             user_term: :x,
             bad_return: :not_ok,
             error: %RuntimeError{message: "boom"},
             throw: :thrown,
             exit: :exited
           } ==
             Map.new(alts, fn {alt, {:computation_error, error}} ->
               {alt, error.reason}
             end)
  end

  test "from a failed key, fetch and attempts walk the dep_failed records down to the leaf" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([:b], ok_body(1)))
      |> Workflow.add_rule(:b, rule([:c], ok_body(1)))
      |> Workflow.add_rule(:c, rule([], error_body(%SomeError{code: 42})))

    {_, wf} = run_failed(wf, [:a])

    assert [
             {:default, :c, %{}},
             :default,
             %{kind: :user_term, reason: %SomeError{code: 42}}
           ] =
             walk_to_leaf(wf, :a)
  end

  @tag :skip
  test "the failures of a target are derived from the records: a target failed by a key that failed in an earlier run holds the records of that run" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([:b], ok_body(1)))
      |> Workflow.add_rule(:b, failing_rule(:b_reason))

    {first, wf} = run_failed(wf, [:b])
    earlier = failures!(wf, first.target)

    {e, wf} = run_failed(wf, [:a])
    assert key(:a) == e.target

    failures = failures!(wf, e.target)
    assert %{default: {:dep_failed, key(:b)}} == failures[key(:a)]
    assert earlier[key(:b)] == failures[key(:b)]
  end

  @tag :skip
  test "a second run of a failed target returns the same computation error, and the same failures" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([:b], ok_body(1)))
      |> Workflow.add_rule(:b, rule([], fn _, _, _ -> raise "boom" end))

    {e1, wf1} = run_failed(wf, [:a])
    {e2, wf2} = run_failed(wf1, [:a])

    assert e1 == e2
    assert Exception.message(e1) == Exception.message(e2)
    assert failures!(wf1, :a) == failures!(wf2, :a)
  end

  test "the target of a computation error is the first target with no value" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:ok, const_rule(1))
      |> Workflow.add_rule(:fail1, failing_rule())
      |> Workflow.add_rule(:fail2, failing_rule())

    {e, _} = run_failed(wf, [:ok, {:fail1, %{id: 1}}, :fail2])
    assert key(:fail1, %{id: 1}) == e.target
  end

  @tag :skip
  test "failures accepts the key forms that run accepts for targets" do
    wf = Workflow.add_rule(Workflow.new(), :a, failing_rule(:a_reason))
    {_, wf} = run_failed(wf, [:a])

    expected = failures!(wf, {:default, :a, %{}})
    assert %{key(:a) => %{default: {:computation_error, :a_reason}}} == outline(expected)
    assert expected == failures!(wf, :a)
    assert expected == failures!(wf, {:a, %{}})
  end

  describe "failures returns {:error, :not_failed}" do
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
      {_, wf} = run_failed(wf, [:fail])
      %{wf: wf}
    end

    @tag :skip
    test "for a key with a value", %{wf: wf} do
      assert {:error, :not_failed} == Workflow.failures(wf, :ok)
    end

    @tag :skip
    test "for a key with attempts but no result", %{wf: wf} do
      assert {:error, :not_failed} == Workflow.failures(wf, :in_progress)
    end

    @tag :skip
    test "for a key with no records", %{wf: wf} do
      assert {:error, :not_failed} == Workflow.failures(wf, :never)
      assert {:error, :not_failed} == Workflow.failures(wf, {:fail, %{id: 1}})
    end
  end

  @tag :skip
  test "failures for a key with no registered rule returns a graph error" do
    wf = Workflow.add_rule(Workflow.new(), :a, failing_rule())

    assert {:error,
            %GraphError{rule: nil, reason: {:unknown_rule, {:default, :missing, %{}}}}} =
             Workflow.failures(wf, :missing)

    assert {:error, %GraphError{reason: {:unknown_rule, {NsA, :a, %{}}}}} =
             Workflow.failures(wf, {NsA, :a, %{}})

    assert {:error, %GraphError{reason: {:invalid_key, "a"}}} = Workflow.failures(wf, "a")
  end

  @tag :skip
  test "a tuple or a capture naming a function that does not exist fails the alternative with kind :error when it is called" do
    for body <- [
          {__MODULE__.NotYet, :body, []},
          Function.capture(__MODULE__.NotYet, :body, 3),
          {__MODULE__, :not_a_function, [1]},
          Function.capture(__MODULE__, :not_a_function, 3)
        ] do
      wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))

      {_, wf} = run_failed(wf, [:a])

      assert {:ok, %{default: {:computation_error, %{kind: :error} = error}}} =
               Workflow.attempts(wf, :a)

      assert error.message =~ "UndefinedFunctionError"
    end
  end
end
