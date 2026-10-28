defmodule Ark.Workflow.UserCodeTest do
  use ExUnit.Case, async: true

  import Ark.Test.Mock
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

  defmodule BlamedError do
    defexception [:message]

    @impl true
    def blame(e, stacktrace) do
      {%{e | message: e.message <> " (enriched by blame)"}, stacktrace}
    end
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

  defp base_graph do
    Workflow.new()
    |> Workflow.add_rule(:a, const_rule(:va))
    |> Workflow.add_rule(:b, const_rule(:vb))
  end

  defp attempt_error(body) do
    wf = Workflow.add_rule(Workflow.new(), :r, rule([], body))
    assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:r])
    assert {:ok, %{default: {:computation_error, cleaned}}} = Workflow.attempts(wf, :r)
    cleaned
  end

  defp deps_attempt_error(deps_fun) do
    wf = Workflow.add_rule(Workflow.new(), :r, rule([deps_fun], ok_body(1)))
    assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:r])
    assert {:ok, %{default: {:computation_error, cleaned}}} = Workflow.attempts(wf, :r)
    cleaned
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

  test "a body returning {:ok, value} records the value under the computed key" do
    value = %{"any" => [:term, {1, 2}], date: ~D[2024-01-01]}
    wf = Workflow.add_rule(Workflow.new(), :r, rule([], ok_body(value)))

    wf = run!(wf, [{:r, %{id: 1}}])

    assert {:ok, value} == Workflow.fetch(wf, {:r, %{id: 1}})
    assert :error == Workflow.fetch(wf, :r)
  end

  describe "a body returning {:error, reason} fails the alternative" do
    test "with kind :user_term and no stacktrace" do
      assert %{kind: :user_term, message: ":some_reason"} =
               attempt_error(error_body(:some_reason))
    end

    test "with the exception message when reason is an exception struct" do
      reason = %DomainError{message: "the account is closed"}

      assert %{kind: :user_term, message: "the account is closed"} =
               attempt_error(error_body(reason))

      reason = %ArgumentError{message: "bad arg"}
      assert %{kind: :user_term, message: "bad arg"} = attempt_error(error_body(reason))
    end

    test "with inspect(reason) when reason is any other term" do
      for reason <- [{:not_found, 123}, "a string", %{a: 1}, [1, 2], nil] do
        assert %{kind: :user_term, message: error} = attempt_error(error_body(reason))
        assert inspect(reason) == error
      end
    end
  end

  test "a body returning anything else fails the alternative with kind :bad_return, no stacktrace, and a message holding the returned value" do
    for value <- [:ok, {:ok, 1, 2}, {:error, 1, 2}, nil, 42, "str", {:error}, %{ok: 1}] do
      assert %{kind: :bad_return, message: error} = attempt_error(fn _, _, _ -> value end)
      assert error =~ inspect(value)
      refute error =~ "04_user_code_test.exs"
    end
  end

  describe "a body that" do
    test "raises fails the alternative with kind :error, the message and a formatted stacktrace" do
      assert %{kind: :error, message: error} =
               attempt_error(fn _, _, _ -> raise "boom" end)

      assert error =~ "(RuntimeError) boom"
      assert error =~ "04_user_code_test.exs"

      assert %{kind: :error, message: error} =
               attempt_error(fn _, _, _ -> raise DomainError, "domain failure" end)

      assert error =~ "DomainError"
      assert error =~ "domain failure"
    end

    test "matches on unexpected params and raises FunctionClauseError is caught like any raise" do
      wf =
        Workflow.add_rule(Workflow.new(), :r, rule([], fn %{id: 1}, _, _ -> {:ok, 1} end))

      assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [{:r, %{id: 2}}])

      assert {:ok, %{default: {:computation_error, %{kind: :error, message: error}}}} =
               Workflow.attempts(wf, {:r, %{id: 2}})

      assert error =~ "FunctionClauseError"
    end

    test "throws fails the alternative with kind :throw" do
      assert %{kind: :throw, message: error} =
               attempt_error(fn _, _, _ -> throw(:thrown_value) end)

      assert error =~ ":thrown_value"
    end

    test "exits fails the alternative with kind :exit, also with reason :normal" do
      assert %{kind: :exit, message: error} =
               attempt_error(fn _, _, _ -> exit(:some_reason) end)

      assert error =~ ":some_reason"

      assert %{kind: :exit, message: error} =
               attempt_error(fn _, _, _ -> exit(:normal) end)

      assert error =~ "normal"
    end
  end

  test "an exception whose message/1 raises, returned or raised, still yields a cleaned error" do
    assert %{kind: :user_term, message: error} =
             attempt_error(error_body(%BrokenMessageError{value: 1}))

    assert is_binary(error)

    assert %{kind: :error, message: error} =
             attempt_error(fn _, _, _ -> raise BrokenMessageError, value: 1 end)

    assert is_binary(error)
  end

  test "a user exception's blame/2 callback enriches its formatted message" do
    assert %{kind: :error, message: error} =
             attempt_error(fn _, _, _ -> raise BlamedError, "original" end)

    assert error =~ "original (enriched by blame)"
  end

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

    test "the returned value for kind :bad_return" do
      assert %{kind: :bad_return, reason: {:ok, 1, 2}} =
               attempt_error(fn _, _, _ -> {:ok, 1, 2} end)
    end

    test "the normalized exception struct for kind :error, also for an Erlang error" do
      assert %{kind: :error, reason: %DomainError{message: "domain failure"}} =
               attempt_error(fn _, _, _ -> raise DomainError, "domain failure" end)

      assert %{kind: :error, reason: %ArgumentError{}} =
               attempt_error(fn _, _, _ -> :erlang.error(:badarg) end)
    end

    test "the thrown value for kind :throw" do
      assert %{kind: :throw, reason: {:thrown, 1}} =
               attempt_error(fn _, _, _ -> throw({:thrown, 1}) end)
    end

    test "the exit reason for kind :exit" do
      assert %{kind: :exit, reason: {:shutdown, :x}} =
               attempt_error(fn _, _, _ -> exit({:shutdown, :x}) end)
    end
  end

  test "a dependency function that raises, throws or exits records the same reason as a body would" do
    assert %{kind: :error, reason: %DomainError{message: "domain failure"}} =
             deps_attempt_error(fn _, _, _ -> raise DomainError, "domain failure" end)

    assert %{kind: :error, reason: %ArgumentError{}} =
             deps_attempt_error(fn _, _, _ -> :erlang.error(:badarg) end)

    assert %{kind: :throw, reason: {:thrown, 1}} =
             deps_attempt_error(fn _, _, _ -> throw({:thrown, 1}) end)

    assert %{kind: :exit, reason: {:shutdown, :x}} =
             deps_attempt_error(fn _, _, _ -> exit({:shutdown, :x}) end)
  end
end
