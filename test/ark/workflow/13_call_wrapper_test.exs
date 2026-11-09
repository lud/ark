defmodule Ark.Workflow.CallWrapperTest.Compiled do
  alias Ark.Test.Mock
  alias Ark.Workflow

  @rule %{alts: [default: %{deps: [], body: {__MODULE__, :body, []}}]}

  @tuple_graph Workflow.new(call_wrapper: {__MODULE__, :wrap, [:tuple]})
               |> Workflow.add_rule(:a, @rule)

  @capture_graph Workflow.new(call_wrapper: &__MODULE__.wrap/3)
                 |> Workflow.add_rule(:a, @rule)

  def tuple_graph do
    @tuple_graph
  end

  def capture_graph do
    @capture_graph
  end

  def body(_params, _deps, _ctx) do
    {:ok, 1}
  end

  def wrap(kind, meta, call) do
    wrap(kind, meta, call, :capture)
  end

  def wrap(kind, meta, {_, _, [_, _, %{log: log} | _]} = call, tag) do
    Mock.track(log, {tag, kind, meta.key})
    Workflow.invoke(call)
  end
end

defmodule Ark.Workflow.CallWrapperTest do
  use ExUnit.Case, async: true

  import Ark.Test.Mock
  import Ark.Test.WorkflowHelpers

  alias Ark.Workflow
  alias Ark.Workflow.CallWrapperTest.Compiled
  alias Ark.Workflow.ComputationError
  alias Ark.Workflow.GraphError

  def mfa_body(params, _deps, _ctx, extra) do
    {:ok, {params, extra}}
  end

  def tuple_wrapper(kind, meta, call, log, tag) do
    track(log, {tag, kind, meta.key})
    Workflow.invoke(call)
  end

  defp tracking(log, tag \\ :wrapper) do
    fn kind, meta, call ->
      track(log, {tag, kind, meta})
      Workflow.invoke(call)
    end
  end

  defp graph do
    Workflow.new()
    |> Workflow.add_rule(:b, const_rule(:vb))
    |> Workflow.add_rule(:a, %{
      alts: [
        a1: %{deps: [], body: error_body()},
        a2: %{deps: [:b, fn _, _, _ -> %{x: :b} end], body: deps_body()}
      ]
    })
  end

  defp two_rules(opts \\ []) do
    Workflow.new(opts)
    |> Workflow.add_rule(:a, const_rule(1))
    |> Workflow.add_rule(:b, const_rule(2))
  end

  defp attempt_error(wf, key) do
    assert %{default: {:computation_error, cleaned}} = Workflow.attempts(wf, key)
    cleaned
  end

  describe "the call wrapper wraps" do
    test "every body call, with kind :computation, and every dependency function call, with kind :deps, receiving the computed key and the alternative name" do
      log = start_log()

      wf = run!(graph(), [{:a, %{id: 1}}], call_wrapper: tracking(log))

      entries = logged(log)
      key_a = {:default, :a, %{id: 1}}
      key_b = {:default, :b, %{}}

      assert {:wrapper, :computation, %{key: key_a, alternative: :a1}} in entries
      assert {:wrapper, :computation, %{key: key_b, alternative: :default}} in entries
      assert {:wrapper, :deps, %{key: key_a, alternative: :a2}} in entries
      assert {:wrapper, :computation, %{key: key_a, alternative: :a2}} in entries

      bodies = Enum.filter(entries, &match?({_, :computation, _}, &1))
      assert 3 == length(bodies)

      assert Enum.all?(
               entries,
               &match?({:wrapper, kind, _} when kind in [:computation, :deps], &1)
             )

      assert %{b: :vb, x: :vb} == fetch!(wf, {:a, %{id: 1}})
    end
  end

  test "the call the wrapper receives is plain data with the arguments of the actual call: {module, function, args} for a tuple, {fun, args} for a function" do
    log = start_log()
    body = ok_body(1)

    wrapper = fn _kind, _meta, call ->
      track(log, call)
      Workflow.invoke(call)
    end

    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([], body))
      |> Workflow.add_rule(:m, rule([], {__MODULE__, :mfa_body, [:extra]}))

    _ = run!(wf, [{:a, %{id: 1}}, :m], context: %{ctx: 1}, call_wrapper: wrapper)

    assert [
             {body, [%{id: 1}, %{}, %{ctx: 1}]},
             {__MODULE__, :mfa_body, [%{}, %{}, %{ctx: 1}, :extra]}
           ] == logged(log)
  end

  describe "invoke(call)" do
    test "runs the user code of the call" do
      {pid, body} = mock_fun(1, ok_body(:from_body))

      wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))
      wf = run!(wf, [:a], call_wrapper: fn _, _, call -> Workflow.invoke(call) end)

      verify(pid)
      assert :from_body == fetch!(wf, :a)

      assert {:ok, {%{}, :extra}} ==
               Workflow.invoke({__MODULE__, :mfa_body, [%{}, %{}, %{}, :extra]})
    end

    test "lets the raises, throws and exits of the user code through" do
      assert_raise RuntimeError, "boom", fn ->
        Workflow.invoke({fn -> raise "boom" end, []})
      end

      assert :thrown == catch_throw(Workflow.invoke({fn -> throw(:thrown) end, []}))
      assert :exited == catch_exit(Workflow.invoke({fn -> exit(:exited) end, []}))
    end
  end

  test "a call wrapper that changes the arguments before invoking the call changes what user code receives, e.g. the context" do
    {pid, body} = mock_fun(1, ok_body(1))

    wrapper = fn _kind, _meta, {fun, [p, d, c]} ->
      Workflow.invoke({fun, [p, d, Map.put(c, :injected, true)]})
    end

    wf = Workflow.add_rule(Workflow.new(), :a, rule([], body))
    _ = run!(wf, [:a], context: %{ctx: 1}, call_wrapper: wrapper)

    verify(pid)
    assert [[%{}, %{}, %{ctx: 1, injected: true}]] == calls(pid)
  end

  test "a call wrapper given as a {module, function, extra_args} tuple is called with extra_args after kind, meta and call" do
    log = start_log()

    _ = run!(two_rules(), [:a], call_wrapper: {__MODULE__, :tuple_wrapper, [log, :tuple]})

    assert [{:tuple, :computation, {:default, :a, %{}}}] == logged(log)
  end

  describe "the call wrapper given to new" do
    test "wraps the calls of every run" do
      log = start_log()

      wf = run!(two_rules(call_wrapper: tracking(log)), [:a])
      _ = run!(wf, [:b])

      assert [
               {:wrapper, :computation, %{key: {:default, :a, %{}}}},
               {:wrapper, :computation, %{key: {:default, :b, %{}}}}
             ] = logged(log)
    end

    test "given as a tuple or a remote capture can be stored with the graph in a module attribute" do
      for {graph, tag} <- [
            {Compiled.tuple_graph(), :tuple},
            {Compiled.capture_graph(), :capture}
          ] do
        log = start_log()

        wf = run!(graph, [:a], context: %{log: log})

        assert 1 == fetch!(wf, :a)
        assert [{tag, :computation, {:default, :a, %{}}}] == logged(log)
      end
    end
  end

  test "the call wrapper given to run replaces the one given to new for that run" do
    log = start_log()

    wf =
      run!(two_rules(call_wrapper: tracking(log, :new)), [:a],
        call_wrapper: tracking(log, :run)
      )

    _ = run!(wf, [:b])

    assert [
             {:run, :computation, %{key: {:default, :a, %{}}}},
             {:new, :computation, %{key: {:default, :b, %{}}}}
           ] = logged(log)
  end

  test "run with call_wrapper: nil calls user code without the wrapper given to new" do
    log = start_log()

    wf = run!(two_rules(call_wrapper: tracking(log)), [:a], call_wrapper: nil)

    assert 1 == fetch!(wf, :a)
    assert [] == logged(log)
  end

  test "new and run raise an invalid value Ark.Opts.Error for a call wrapper that is neither a function of arity 3 nor a {module, function, list} tuple" do
    wf = two_rules()

    for bad <- [
          fn _ -> :x end,
          fn _, _, _, _ -> :x end,
          {__MODULE__, :tuple_wrapper},
          {"Elixir.Mod", :fun, []},
          {__MODULE__, :tuple_wrapper, :not_a_list},
          :not_a_wrapper,
          1
        ] do
      assert %Ark.Opts.Error{kind: :invalid_value} =
               assert_raise(Ark.Opts.Error, fn -> Workflow.new(call_wrapper: bad) end)

      assert %Ark.Opts.Error{kind: :invalid_value} =
               assert_raise(Ark.Opts.Error, fn ->
                 Workflow.run(wf, [:a], call_wrapper: bad)
               end)
    end
  end

  describe "a call wrapper that does not invoke the call" do
    test "replaces the body result with its own return value and prevents the user code from running" do
      {pid, never} = mock_never(ok_body(:from_body))
      wrapper = fn :computation, _meta, _call -> {:ok, :from_wrapper} end

      wf = Workflow.add_rule(Workflow.new(), :a, rule([], never))
      wf = run!(wf, [:a], call_wrapper: wrapper)

      verify(pid)
      assert :from_wrapper == fetch!(wf, :a)
    end

    test "around a dependency function supplies the keys to demand" do
      {pid, never} = mock_never(fn _, _, _ -> :a end)

      wrapper = fn
        :deps, _meta, _call -> %{supplied: :b}
        :computation, _meta, call -> Workflow.invoke(call)
      end

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, const_rule(:va))
        |> Workflow.add_rule(:b, const_rule(:vb))
        |> Workflow.add_rule(:r, rule([never], deps_body()))

      wf = run!(wf, [:r], call_wrapper: wrapper)

      verify(pid)
      assert %{supplied: :vb} == fetch!(wf, :r)
      assert :error == Workflow.fetch(wf, :a)
    end
  end

  test "a call wrapper that raises, throws or exits fails the alternative the same way user code does" do
    wrapper = fn _, _, _ -> raise "wrapper boom" end
    wf = Workflow.add_rule(Workflow.new(), :a, const_rule(1))

    assert {:error, %ComputationError{}, wf} =
             Workflow.run(wf, [:a], call_wrapper: wrapper)

    assert %{kind: :error, message: error, stacktrace: st} = attempt_error(wf, :a)
    assert error =~ "wrapper boom"
    assert st =~ "13_call_wrapper_test.exs"

    deps_wrapper = fn
      :deps, _, _ -> throw(:wrapper_throw)
      :computation, _, call -> Workflow.invoke(call)
    end

    wf =
      Workflow.new()
      |> Workflow.add_rule(:b, const_rule(1))
      |> Workflow.add_rule(:a, rule([fn _, _, _ -> :b end], ok_body(1)))

    assert {:error, %ComputationError{}, failed} =
             Workflow.run(wf, [:a], call_wrapper: deps_wrapper)

    assert %{kind: :throw, stacktrace: st} = attempt_error(failed, :a)
    assert st =~ "13_call_wrapper_test.exs"

    exit_wrapper = fn _, _, _ -> exit(:wrapper_exit) end

    assert {:error, %ComputationError{}, failed} =
             Workflow.run(wf, [:a], call_wrapper: exit_wrapper)

    assert %{kind: :exit} = attempt_error(failed, :a)
  end

  test "a call wrapper around a body returning an invalid value fails the alternative with kind :bad_return" do
    for value <- [:not_a_result, {:error, :comp, 1}, {:error, :graph, 1}] do
      wrapper = fn :computation, _, call ->
        {:ok, _} = Workflow.invoke(call)
        value
      end

      wf = Workflow.add_rule(Workflow.new(), :a, const_rule(1))

      assert {:error, %ComputationError{}, wf} =
               Workflow.run(wf, [:a], call_wrapper: wrapper)

      assert %{kind: :bad_return, message: error, reason: ^value} = attempt_error(wf, :a)
      assert Ark.Error.to_string(value) == error
    end
  end

  test "a call wrapper around a dependency function returning an invalid dependency makes run stop with a graph error" do
    wrapper = fn
      :deps, _, _ -> "not a key"
      :computation, _, call -> Workflow.invoke(call)
    end

    fun = fn _, _, _ -> :b end

    wf =
      Workflow.new()
      |> Workflow.add_rule(:b, const_rule(1))
      |> Workflow.add_rule(:a, rule([fun], ok_body(1)))

    assert {:error, %GraphError{reason: reason}, wf} =
             Workflow.run(wf, [:a], call_wrapper: wrapper)

    assert {:bad_return, :deps, ^fun, "not a key", {:invalid_key, "not a key"}} = reason

    assert :error == Workflow.fetch(wf, :a)
  end

  test "a call wrapper that rescues a raise from user code and returns {:ok, value} records the value" do
    wrapper = fn :computation, _, call ->
      try do
        Workflow.invoke(call)
      rescue
        _ -> {:ok, :rescued}
      end
    end

    wf = Workflow.add_rule(Workflow.new(), :a, rule([], fn _, _, _ -> raise "boom" end))
    wf = run!(wf, [:a], call_wrapper: wrapper)

    assert :rescued == fetch!(wf, :a)
    assert %{} == Workflow.attempts(wf, :a)
  end

  test "the call wrapper is not dumped: after a load, calls are wrapped by the wrapper of the workflow given to load, or by the one given to run" do
    log = start_log()

    wf = run!(two_rules(call_wrapper: tracking(log, :dumped)), [:a])
    wf = roundtrip(wf, two_rules(call_wrapper: tracking(log, :loaded)))
    wf = run!(wf, [:a, :b])
    _ = run!(wf, [{:b, %{id: 1}}], call_wrapper: tracking(log, :run))

    assert [
             {:dumped, :computation, %{key: {:default, :a, %{}}}},
             {:loaded, :computation, %{key: {:default, :b, %{}}}},
             {:run, :computation, %{key: {:default, :b, %{id: 1}}}}
           ] = logged(log)
  end
end
