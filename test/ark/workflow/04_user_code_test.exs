defmodule Ark.Workflow.UserCodeTest do
  use ExUnit.Case, async: true

  import Ark.Test.WorkflowHelpers

  alias Ark.Workflow
  alias Ark.Workflow.ComputationError

  defmodule DomainError do
    defexception [:message]
  end

  defmodule BrokenMessageError do
    defexception [:value]

    @impl true
    def message(_) do
      raise("cannot format")
    end
  end

  defp attempt_error(body) do
    wf = Workflow.add_rule(Workflow.new(), :r, rule([], body))
    assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:r])
    assert {:ok, %{default: {:computation_error, cleaned}}} = Workflow.attempts(wf, :r)
    cleaned
  end

  test "a body returning {:ok, value} records the value under the computed key" do
    value = %{"any" => [:term, {1, 2}], date: ~D[2024-01-01]}
    wf = Workflow.add_rule(Workflow.new(), :r, rule([], ok_body(value)))

    wf = run!(wf, [{:r, %{id: 1}}])

    assert {:ok, value} == Workflow.fetch(wf, {:r, %{id: 1}})
    assert :error == Workflow.fetch(wf, :r)
  end

  describe "a body returning {:error, reason} fails the alternative" do
    @tag :skip
    test "with kind :user_term and no stacktrace" do
      assert %{kind: :user_term, message: ":some_reason", stacktrace: nil} =
               attempt_error(error_body(:some_reason))
    end

    test "with the exception message when reason is an exception struct" do
      reason = %DomainError{message: "the account is closed"}

      assert %{kind: :user_term, message: "the account is closed"} =
               attempt_error(error_body(reason))

      reason = %ArgumentError{message: "bad arg"}
      assert %{kind: :user_term, message: "bad arg"} = attempt_error(error_body(reason))
    end

    test "with the Ark.Error rendering of reason for any other term" do
      for reason <- [{:not_found, 123}, "a string", %{a: 1}, [1, 2], nil, {:shutdown, :x}] do
        assert %{kind: :user_term, message: error} = attempt_error(error_body(reason))
        assert Ark.Error.to_string(reason) == error
      end
    end
  end

  @tag :skip
  test "a body returning anything else fails the alternative with kind :bad_return, no stacktrace, and the Ark.Error rendering of the returned value as message" do
    for value <- [:ok, {:ok, 1, 2}, {:error, 1, 2}, nil, 42, "str", {:error}, %{ok: 1}] do
      assert %{kind: :bad_return, message: error, stacktrace: nil} =
               attempt_error(fn _, _, _ -> value end)

      assert Ark.Error.to_string(value) == error
    end
  end

  describe "a body that" do
    @tag :skip
    test "raises fails the alternative with kind :error, a message naming the exception, and a formatted stacktrace" do
      assert %{kind: :error, message: error, stacktrace: stacktrace} =
               attempt_error(fn _, _, _ -> raise "boom" end)

      assert error =~ "(RuntimeError) boom"
      refute error =~ "04_user_code_test.exs"
      assert stacktrace =~ "04_user_code_test.exs"

      assert %{kind: :error, message: error} =
               attempt_error(fn _, _, _ -> raise DomainError, "domain failure" end)

      assert error =~ "DomainError"
      assert error =~ "domain failure"
    end

    @tag :skip
    test "matches on unexpected params and raises FunctionClauseError is caught like any raise, with no argument value in its message or stacktrace" do
      wf =
        Workflow.add_rule(Workflow.new(), :r, rule([], fn %{id: 1}, _, _ -> {:ok, 1} end))

      key = {:r, %{id: 2, token: "s3cr3t"}}
      assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [key])

      assert {:ok,
              %{
                default:
                  {:computation_error,
                   %{kind: :error, message: error, stacktrace: stacktrace}}
              }} = Workflow.attempts(wf, key)

      assert error =~ "FunctionClauseError"
      refute error =~ "s3cr3t"
      assert stacktrace =~ "04_user_code_test.exs"
      refute stacktrace =~ "s3cr3t"
    end

    @tag :skip
    test "throws fails the alternative with kind :throw" do
      assert %{kind: :throw, message: error, stacktrace: stacktrace} =
               attempt_error(fn _, _, _ -> throw(:thrown_value) end)

      assert error =~ ":thrown_value"
      assert stacktrace =~ "04_user_code_test.exs"
    end

    @tag :skip
    test "exits fails the alternative with kind :exit, also with reason :normal" do
      assert %{kind: :exit, message: error, stacktrace: stacktrace} =
               attempt_error(fn _, _, _ -> exit(:some_reason) end)

      assert error =~ ":some_reason"
      assert stacktrace =~ "04_user_code_test.exs"

      assert %{kind: :exit, message: error} =
               attempt_error(fn _, _, _ -> exit(:normal) end)

      assert error =~ "normal"
    end
  end

  @tag :skip
  test "an exception whose message/1 raises, returned or raised, still yields a cleaned error" do
    assert %{kind: :user_term, message: error} =
             attempt_error(error_body(%BrokenMessageError{value: 1}))

    assert is_binary(error)

    assert %{kind: :error, message: error} =
             attempt_error(fn _, _, _ -> raise BrokenMessageError, value: 1 end)

    assert is_binary(error)
  end

  @tag :skip
  test "every cleaned error carries the time it was recorded" do
    before = DateTime.utc_now()

    for body <- [
          error_body(),
          fn _, _, _ -> :bad end,
          fn _, _, _ -> raise "x" end,
          fn _, _, _ -> throw(:x) end,
          fn _, _, _ -> exit(:x) end
        ] do
      assert %{at: %DateTime{} = at} = attempt_error(body)
      assert DateTime.compare(at, before) in [:gt, :eq]
      assert DateTime.compare(at, DateTime.utc_now()) in [:lt, :eq]
    end
  end

  describe "the reason of a cleaned error is the original term" do
    test "the reason of {:error, reason} for kind :user_term" do
      reason = %DomainError{message: "the account is closed"}

      assert %{kind: :user_term, message: "the account is closed", reason: ^reason} =
               attempt_error(error_body(reason))

      assert %{kind: :user_term, reason: {:not_found, 123}} =
               attempt_error(error_body({:not_found, 123}))
    end

    @tag :skip
    test "the returned value for kind :bad_return" do
      assert %{kind: :bad_return, reason: {:ok, 1, 2}} =
               attempt_error(fn _, _, _ -> {:ok, 1, 2} end)
    end

    @tag :skip
    test "the normalized exception struct for kind :error, also for an Erlang error" do
      assert %{kind: :error, reason: %DomainError{message: "domain failure"}} =
               attempt_error(fn _, _, _ -> raise DomainError, "domain failure" end)

      assert %{kind: :error, reason: %ArgumentError{}} =
               attempt_error(fn _, _, _ -> :erlang.error(:badarg) end)
    end

    @tag :skip
    test "the thrown value for kind :throw" do
      assert %{kind: :throw, reason: {:thrown, 1}} =
               attempt_error(fn _, _, _ -> throw({:thrown, 1}) end)
    end

    @tag :skip
    test "the exit reason for kind :exit" do
      assert %{kind: :exit, reason: {:shutdown, :x}} =
               attempt_error(fn _, _, _ -> exit({:shutdown, :x}) end)
    end
  end
end
