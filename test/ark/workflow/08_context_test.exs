defmodule Ark.Workflow.ContextTest do
  use ExUnit.Case, async: true

  import Ark.Test.Mock
  import Ark.Test.WorkflowHelpers

  alias Ark.Workflow

  @tag :skip
  test "user code receives the context given to the run, unchanged" do
    context = %{
      pid: self(),
      ref: make_ref(),
      fun: &String.upcase/1,
      nested: %{"a" => [1, {2}]}
    }

    {pid, body} = mock_fun(1, ok_body(1))
    wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))

    _ = run!(wf, [:a], context: context)

    verify(pid)
    assert [[%{}, %{}, ^context]] = calls(pid)
  end

  test "the context defaults to an empty map" do
    {pid, body} = mock_fun(1, ok_body(1))
    wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))

    _ = run!(wf, [:a])

    verify(pid)
    assert [[%{}, %{}, %{}]] = calls(pid)
  end

  @tag :skip
  test "a body and a dependency function receive the same context" do
    context = %{ctx: make_ref()}
    {deps_pid, deps_fun} = mock_fun(100, fn _, _, _ -> :b end)
    {body_pid, body} = mock_fun(2, ok_body(1))

    wf =
      Workflow.new()
      |> Workflow.add_rule(:b, rule([], body))
      |> Workflow.add_rule(:a, rule([deps_fun], body))

    _ = run!(wf, [:a], context: context)

    verify(body_pid)
    assert Enum.all?(calls(deps_pid), &match?([_, _, ^context], &1))
    assert Enum.all?(calls(body_pid), &match?([_, _, ^context], &1))
  end

  @tag :skip
  test "an alternative receives nothing about why previous alternatives failed" do
    context = %{ctx: 1}
    {pid, body} = mock_fun(1, deps_body())

    wf =
      Workflow.new()
      |> Workflow.add_rule(:b, const_rule(:vb))
      |> Workflow.add_rule(:a, %{
        alts: [
          a1: %{deps: [], body: error_body(:secret_reason)},
          a2: %{deps: [], body: fn _, _, _ -> raise "secret raise" end},
          a3: %{deps: [:b], body: body}
        ]
      })

    wf = run!(wf, [{:a, %{id: 1}}], context: context)

    verify(pid)
    assert [[%{id: 1}, %{b: :vb}, ^context]] = calls(pid)
    assert %{b: :vb} == fetch!(wf, {:a, %{id: 1}})
  end

  test "changing the context between runs does not compute recorded keys again" do
    {pid, body} = mock_fun(1, ok_body(1))
    wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))

    wf = run!(wf, [:a], context: %{v: 1})
    _ = run!(wf, [:a], context: %{v: 2})

    verify(pid)
  end
end
