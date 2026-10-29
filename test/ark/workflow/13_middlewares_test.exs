defmodule Ark.Workflow.MiddlewaresTest do
  use ExUnit.Case, async: true

  import Ark.Test.Mock
  import Ark.Test.WorkflowHelpers
  import ExUnit.CaptureLog

  alias Ark.Workflow
  alias Ark.Workflow.ComputationError
  alias Ark.Workflow.GraphError
  alias Ark.Workflow.Middleware

  def mfa_body(params, _deps, _ctx, extra) do
    {:ok, {params, extra}}
  end

  defp invoke({fun, args}) when is_function(fun) do
    apply(fun, args)
  end

  defp invoke({m, f, args}) do
    apply(m, f, args)
  end

  defp passthrough(log, tag) do
    fn kind, meta, call ->
      track(log, {tag, kind, meta})
      invoke(call)
    end
  end

  defp graph do
    Workflow.new()
    |> Workflow.add_rule(:b, const_rule(:vb))
    |> Workflow.add_rule(:a, %{
      alts: [
        first: %{deps: [], body: error_body()},
        second: %{deps: [:b, fn _, _, _ -> %{x: :b} end], body: deps_body()}
      ]
    })
  end

  defp attempt_error(wf, key) do
    assert {:ok, %{default: {:computation_error, cleaned}}} = Workflow.attempts(wf, key)
    cleaned
  end

  describe "a middleware wraps" do
    test "every body call, with kind :computation, and every dependency function call, with kind :deps, receiving the computed key and the alternative name" do
      log = start_log()

      wf = run!(graph(), [{:a, %{id: 1}}], middlewares: [passthrough(log, :mw)])

      entries = logged(log)
      key_a = {:default, :a, %{id: 1}}
      key_b = {:default, :b, %{}}

      assert {:mw, :computation, %{key: key_a, alternative: :first}} in entries
      assert {:mw, :computation, %{key: key_b, alternative: :default}} in entries
      assert {:mw, :deps, %{key: key_a, alternative: :second}} in entries
      assert {:mw, :computation, %{key: key_a, alternative: :second}} in entries

      bodies = Enum.filter(entries, &match?({_, :computation, _}, &1))
      assert 3 == length(bodies)

      assert Enum.all?(
               entries,
               &match?({:mw, kind, _} when kind in [:computation, :deps], &1)
             )

      assert %{b: :vb, x: :vb} == fetch!(wf, {:a, %{id: 1}})
    end
  end

  test "middlewares apply in list order, the first one outermost" do
    log = start_log()

    mw = fn tag ->
      fn _kind, _meta, call ->
        track(log, {:enter, tag})
        result = invoke(call)
        track(log, {:exit, tag})
        result
      end
    end

    body = fn _, _, _ ->
      track(log, :body)
      {:ok, 1}
    end

    wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))
    _ = run!(wf, [:a], middlewares: [mw.(1), mw.(2)])

    assert [{:enter, 1}, {:enter, 2}, :body, {:exit, 2}, {:exit, 1}] == logged(log)
  end

  describe "the call a middleware receives" do
    test "is plain data: {module, function, args} or {fun, args}" do
      log = start_log()
      body = ok_body(1)

      mw = fn tag ->
        fn _kind, _meta, call ->
          track(log, {tag, call})
          invoke(call)
        end
      end

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([], body))
        |> Workflow.add_rule(:m, rule([], {__MODULE__, :mfa_body, [:extra]}))

      _ =
        run!(wf, [{:a, %{id: 1}}, :m],
          context: %{ctx: 1},
          middlewares: [mw.(:outer), mw.(:inner)]
        )

      assert [{:outer, outer_a}, {:inner, inner_a}, {:outer, outer_m}, {:inner, inner_m}] =
               logged(log)

      assert {body, [%{id: 1}, %{}, %{ctx: 1}]} == inner_a
      assert {__MODULE__, :mfa_body, [%{}, %{}, %{ctx: 1}, :extra]} == inner_m

      for outer <- [outer_a, outer_m] do
        assert {m, f, args} = outer
        assert is_atom(m) and is_atom(f) and is_list(args)
      end
    end

    test "runs the next middleware when invoked, and the user code for the last middleware" do
      {pid, body} = mock_fun(1, ok_body(:from_body))
      log = start_log()

      wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))
      wf = run!(wf, [:a], middlewares: [passthrough(log, 1), passthrough(log, 2)])

      verify(pid)
      assert [{1, :computation, _}, {2, :computation, _}] = logged(log)
      assert :from_body == fetch!(wf, :a)
    end
  end

  test "innermost(call) returns the user code call with its actual arguments" do
    log = start_log()
    body = ok_body(1)

    outer = fn _kind, _meta, call ->
      track(log, Middleware.innermost(call))
      invoke(call)
    end

    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([], body))
      |> Workflow.add_rule(:m, rule([], {__MODULE__, :mfa_body, [:extra]}))

    _ =
      run!(wf, [{:a, %{id: 1}}, :m],
        context: %{ctx: 1},
        middlewares: [outer, passthrough(start_log(), :inner)]
      )

    assert [
             {body, [%{id: 1}, %{}, %{ctx: 1}]},
             {__MODULE__, :mfa_body, [%{}, %{}, %{ctx: 1}, :extra]}
           ] == logged(log)
  end

  test "update_args(call, fun) rewrites the user code arguments through the chain, e.g. to change the context seen by the body" do
    log = start_log()
    {pid, body} = mock_fun(1, ok_body(1))

    outer = fn _kind, _meta, call ->
      call
      |> Middleware.update_args(fn [p, d, c] -> [p, d, Map.put(c, :injected, true)] end)
      |> invoke()
    end

    inner = fn _kind, _meta, call ->
      track(log, Middleware.innermost(call))
      invoke(call)
    end

    wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))
    _ = run!(wf, [:a], context: %{ctx: 1}, middlewares: [outer, inner])

    verify(pid)
    assert [[%{}, %{}, %{ctx: 1, injected: true}]] == calls(pid)
    assert [{_, [%{}, %{}, %{ctx: 1, injected: true}]}] = logged(log)
  end

  describe "a middleware that does not invoke the call" do
    test "replaces the body result with its own return value and prevents the user code from running" do
      {pid, never} = mock_never(ok_body(:from_body))
      mw = fn :computation, _meta, _call -> {:ok, :from_middleware} end

      wf = Workflow.add_rule(Workflow.new(), :a, rule([], never))
      wf = run!(wf, [:a], middlewares: [mw])

      verify(pid)
      assert :from_middleware == fetch!(wf, :a)
    end

    test "for :deps supplies the keys to demand" do
      {pid, never} = mock_never(fn _, _, _ -> :a end)

      mw = fn
        :deps, _meta, _call -> %{supplied: :b}
        :computation, _meta, call -> invoke(call)
      end

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, const_rule(:va))
        |> Workflow.add_rule(:b, const_rule(:vb))
        |> Workflow.add_rule(:r, rule([never], deps_body()))

      wf = run!(wf, [:r], middlewares: [mw])

      verify(pid)
      assert %{supplied: :vb} == fetch!(wf, :r)
      assert :error == Workflow.fetch(wf, :a)
    end
  end

  test "a middleware that raises fails the alternative the same way user code does" do
    mw = fn _, _, _ -> raise "middleware boom" end
    wf = Workflow.add_rule(Workflow.new(), :a, const_rule(1))

    assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a], middlewares: [mw])
    assert %{kind: :error, message: error} = attempt_error(wf, :a)
    assert error =~ "middleware boom"

    deps_mw = fn
      :deps, _, _ -> throw(:middleware_throw)
      :computation, _, call -> invoke(call)
    end

    wf =
      Workflow.new()
      |> Workflow.add_rule(:b, const_rule(1))
      |> Workflow.add_rule(:a, rule([fn _, _, _ -> :b end], ok_body(1)))

    assert {:error, %ComputationError{}, wf} =
             Workflow.run(wf, [:a], middlewares: [deps_mw])

    assert %{kind: :throw} = attempt_error(wf, :a)
  end

  test "a middleware wrapping a body and returning an invalid value fails the alternative with kind :bad_return" do
    mw = fn :computation, _, call ->
      {:ok, _} = invoke(call)
      :not_a_result
    end

    wf = Workflow.add_rule(Workflow.new(), :a, const_rule(1))

    assert {:error, %ComputationError{}, wf} = Workflow.run(wf, [:a], middlewares: [mw])
    assert %{kind: :bad_return, message: error} = attempt_error(wf, :a)
    assert error =~ ":not_a_result"
  end

  test "a middleware wrapping a dependency function and returning an invalid dependency makes run stop with a graph error" do
    mw = fn
      :deps, _, _ -> "not a key"
      :computation, _, call -> invoke(call)
    end

    fun = fn _, _, _ -> :b end

    wf =
      Workflow.new()
      |> Workflow.add_rule(:b, const_rule(1))
      |> Workflow.add_rule(:a, rule([fun], ok_body(1)))

    assert {:error, %GraphError{reason: reason}, wf} =
             Workflow.run(wf, [:a], middlewares: [mw])

    assert {:bad_return, :deps, ^fun, "not a key", {:invalid_key, "not a key"}} = reason

    assert :error == Workflow.fetch(wf, :a)
  end

  test "a middleware that rescues a raise from user code and returns {:ok, value} records the value" do
    mw = fn :computation, _, call ->
      try do
        invoke(call)
      rescue
        _ -> {:ok, :rescued}
      end
    end

    wf = Workflow.add_rule(Workflow.new(), :a, rule([], fn _, _, _ -> raise "boom" end))
    wf = run!(wf, [:a], middlewares: [mw])

    assert :rescued == fetch!(wf, :a)
    assert {:ok, %{}} == Workflow.attempts(wf, :a)
  end

  test "middlewares are not persisted: a run after a load uses only the middlewares given to that run" do
    log = start_log()

    graph =
      Workflow.new()
      |> Workflow.add_rule(:a, const_rule(1))
      |> Workflow.add_rule(:b, const_rule(2))

    wf = run!(graph, [:a], middlewares: [passthrough(log, :first)])
    wf = roundtrip(wf, graph)
    wf = run!(wf, [:b])

    assert 2 == fetch!(wf, :b)

    assert [{:first, :computation, %{key: {:default, :a, %{}}}}] = logged(log)
  end

  test "the provided logging middleware logs each call to user code" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:logged_dep, const_rule(1))
      |> Workflow.add_rule(
        :logged_target,
        rule([fn _, _, _ -> :logged_dep end], ok_body(1))
      )

    log =
      capture_log(fn ->
        _ = run!(wf, [:logged_target], middlewares: [&Middleware.log/3])
      end)

    assert log =~ ":logged_target"
    assert log =~ ":logged_dep"
  end

  test "the provided telemetry middleware emits events for each call to user code" do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:ark, :workflow, :call, :start], [:ark, :workflow, :call, :stop]],
        fn event, _measurements, meta, _ -> send(test_pid, {:telemetry, event, meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    wf =
      Workflow.new()
      |> Workflow.add_rule(:dep, const_rule(1))
      |> Workflow.add_rule(:target, rule([fn _, _, _ -> :dep end], ok_body(1)))

    _ = run!(wf, [:target], middlewares: [&Middleware.telemetry/3])

    target = {:default, :target, %{}}
    dep = {:default, :dep, %{}}

    assert_received {:telemetry, [:ark, :workflow, :call, :start],
                     %{kind: :deps, key: ^target, alternative: :default}}

    assert_received {:telemetry, [:ark, :workflow, :call, :stop],
                     %{kind: :deps, key: ^target}}

    assert_received {:telemetry, [:ark, :workflow, :call, :start],
                     %{kind: :computation, key: ^dep}}

    assert_received {:telemetry, [:ark, :workflow, :call, :stop],
                     %{kind: :computation, key: ^dep}}

    assert_received {:telemetry, [:ark, :workflow, :call, :start],
                     %{kind: :computation, key: ^target}}

    assert_received {:telemetry, [:ark, :workflow, :call, :stop],
                     %{kind: :computation, key: ^target}}
  end
end
