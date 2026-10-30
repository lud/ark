defmodule Ark.Workflow.ComputationErrorTest do
  use ExUnit.Case, async: true

  import Ark.Test.WorkflowHelpers

  alias Ark.Workflow
  alias Ark.Workflow.ComputationError

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

  describe "when :a needs :b, :b needs :c and :c fails" do
    setup do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, %{alts: [main: %{deps: [:b], body: ok_body(1)}]})
        |> Workflow.add_rule(:b, %{
          alts: [main: %{deps: [{:c, %{id: 1}}], body: ok_body(1)}]
        })
        |> Workflow.add_rule(:c, %{
          alts: [main: %{deps: [], body: error_body(:leaf_reason)}]
        })

      %{wf: wf}
    end

    test "the failure of :a points to :b only", %{wf: wf} do
      {_, wf} = run_failed(wf, [:a])
      assert {:ok, %{main: {:dep_failed, key(:b)}}} == Workflow.attempts(wf, :a)
    end

    test "the computation error for target :a has the error of :c as its single cause, and its message describes the chain down to it",
         %{wf: wf} do
      {e, _} = run_failed(wf, [:a])

      assert key(:a) == e.target

      assert [
               %{
                 key: {:default, :c, %{id: 1}},
                 alternative: :main,
                 error: %{kind: :user_term, message: ":leaf_reason"}
               }
             ] =
               e.causes

      message = Exception.message(e)
      assert message =~ ":a"
      assert message =~ ":b"
      assert message =~ "{:c, %{id: 1}}"
      assert message =~ ":leaf_reason"
    end
  end

  test "the computation error for a target whose alternatives failed on different branches lists every leaf as a cause, in evaluation order" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, %{
        alts: [
          first: %{deps: [:b], body: ok_body(1)},
          second: %{deps: [], body: error_body(:a_reason)},
          third: %{deps: [:mid], body: ok_body(1)}
        ]
      })
      |> Workflow.add_rule(:b, failing_rule(:b_reason))
      |> Workflow.add_rule(:mid, %{
        alts: [
          x: %{deps: [:c], body: ok_body(1)},
          y: %{deps: [], body: fn _, _, _ -> raise "mid raise" end}
        ]
      })
      |> Workflow.add_rule(:c, failing_rule(:c_reason))

    {e, _} = run_failed(wf, [:a])

    assert [
             %{
               key: {:default, :b, %{}},
               alternative: :default,
               error: %{message: ":b_reason"}
             },
             %{
               key: {:default, :a, %{}},
               alternative: :second,
               error: %{message: ":a_reason"}
             },
             %{
               key: {:default, :c, %{}},
               alternative: :default,
               error: %{message: ":c_reason"}
             },
             %{key: {:default, :mid, %{}}, alternative: :y, error: %{kind: :error}}
           ] = e.causes

    message = Exception.message(e)

    for fragment <- [":b_reason", ":a_reason", ":c_reason", "mid raise", ":mid"] do
      assert message =~ fragment
    end
  end

  test "the causes of a computation error hold the cleaned error of each leaf, with its kind and its reason" do
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

    {e, _} = run_failed(wf, [:a])

    assert [:user_term, :bad_return, :error, :throw, :exit] ==
             Enum.map(e.causes, & &1.alternative)

    for %{alternative: alt, error: error} <- e.causes do
      assert %{kind: ^alt, message: message, at: %DateTime{}} = error
      assert is_binary(message)
    end

    assert [:x, :not_ok, %RuntimeError{message: "boom"}, :thrown, :exited] ==
             Enum.map(e.causes, & &1.error.reason)
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

  test "the computation error is derived from the records: a target failed by a key that failed in an earlier run" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([:b], ok_body(1)))
      |> Workflow.add_rule(:b, failing_rule(:b_reason))

    {first, wf} = run_failed(wf, [:b])
    {e, _} = run_failed(wf, [:a])

    assert key(:a) == e.target
    assert first.causes == e.causes
    assert [%{key: {:default, :b, %{}}, error: %{message: ":b_reason"}}] = e.causes
  end

  test "a second run of a failed target returns the same computation error" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([:b], ok_body(1)))
      |> Workflow.add_rule(:b, rule([], fn _, _, _ -> raise "boom" end))

    {e1, wf} = run_failed(wf, [:a])
    {e2, _} = run_failed(wf, [:a])

    assert e1 == e2
    assert Exception.message(e1) == Exception.message(e2)
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

  test "a tuple or a capture naming a function that does not exist fails the alternative with kind :error when it is called" do
    for body <- [
          {__MODULE__.NotYet, :body, []},
          Function.capture(__MODULE__.NotYet, :body, 3),
          {__MODULE__, :not_a_function, [1]},
          Function.capture(__MODULE__, :not_a_function, 3)
        ] do
      wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))

      assert {:error, %ComputationError{causes: [cause]}, _} = Workflow.run(wf, [:a])

      assert %{key: {:default, :a, %{}}, alternative: :default, error: %{kind: :error}} =
               cause

      assert cause.error.message =~ "UndefinedFunctionError"
    end
  end
end
