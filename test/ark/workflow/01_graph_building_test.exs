defmodule Ark.Workflow.GraphBuildingTest.CompiledNs do
  alias Ark.Workflow

  @graph Workflow.new()
         |> Workflow.add_ns(Ark.Workflow.GraphBuildingTest.Billing, fn g ->
           g
           |> Workflow.add_rule(:account, %{
             alts: [default: %{deps: [], body: &__MODULE__.account/3}]
           })
           |> Workflow.add_rule({:default, :entry}, %{
             alts: [
               default: %{
                 deps: [{Ark.Workflow.GraphBuildingTest.Billing, :account, %{}}],
                 body: &__MODULE__.entry/3
               }
             ]
           })
         end)

  def graph do
    @graph
  end

  def account(_params, _deps, _ctx) do
    {:ok, :the_account}
  end

  def entry(_params, deps, _ctx) do
    {:ok, {:entry, Map.values(deps)}}
  end
end

defmodule Ark.Workflow.GraphBuildingTest do
  use ExUnit.Case, async: true

  import Ark.Test.Mock
  import Ark.Test.WorkflowHelpers

  alias Ark.Workflow
  alias Ark.Workflow.GraphBuildingTest.CompiledNs
  alias Ark.Workflow.GraphError

  defmodule NsA do
  end

  defmodule NsB do
  end

  defmodule Billing do
  end

  defp assert_rejected(rule_map) do
    e = assert_raise GraphError, fn -> Workflow.add_rule(Workflow.new(), :r, rule_map) end
    assert {:default, :r} == e.rule
    assert nil == e.key
    e
  end

  defp assert_invalid_rule(rule_map) do
    assert {:invalid_rule, %Ark.Opts.Error{}} = assert_rejected(rule_map).reason
  end

  defp rejected_dep_reason(dep) do
    rejected_deps_reason([dep])
  end

  defp rejected_deps_reason(deps) do
    e = assert_rejected(rule(deps, ok_body(1)))
    assert :default == e.alternative
    e.reason
  end

  defp assert_invalid_identity(identity) do
    e =
      assert_raise GraphError, fn ->
        Workflow.add_rule(Workflow.new(), identity, const_rule(1))
      end

    assert {:invalid_identity, identity} == e.reason
    assert nil == e.rule
  end

  describe "registering a rule" do
    test "twice under the same {ns, name} is an error" do
      wf = Workflow.add_rule(Workflow.new(), :a, const_rule(1))

      e = assert_raise GraphError, fn -> Workflow.add_rule(wf, :a, const_rule(2)) end

      assert %GraphError{rule: {:default, :a}, reason: {:duplicate_rule, {:default, :a}}} =
               e

      e =
        assert_raise GraphError, fn ->
          Workflow.add_rule(wf, {:default, :a}, const_rule(2))
        end

      assert {:duplicate_rule, {:default, :a}} == e.reason

      wf = Workflow.add_rule(wf, {NsA, :a}, const_rule(1))

      e =
        assert_raise GraphError, fn -> Workflow.add_rule(wf, {NsA, :a}, const_rule(2)) end

      assert %GraphError{rule: {NsA, :a}, reason: {:duplicate_rule, {NsA, :a}}} = e
    end

    test "with an empty alternative list is an error" do
      assert_invalid_rule(%{alts: []})
    end

    test "with two alternatives of the same name is an error" do
      alt = %{deps: [], body: ok_body(1)}
      assert_invalid_rule(%{alts: [one: alt, two: alt, one: alt]})
    end

    test "under a string ns or name is rejected" do
      assert_invalid_identity(Enum.random(["a"]))
      assert_invalid_identity({"Elixir.NsA", :a})
      assert_invalid_identity({NsA, "a"})
    end

    test "with a string alternative name is rejected" do
      assert_invalid_rule(%{alts: [{"default", %{deps: [], body: ok_body(1)}}]})
    end

    test "with an ns, name or alternative name that is neither an atom nor a string is rejected" do
      for bad <- [1, {:a, :b, :c}, [:a], %{}] do
        assert_invalid_identity(bad)
        assert_invalid_identity({bad, :a})
        assert_invalid_identity({NsA, bad})
        assert_invalid_rule(%{alts: [{bad, %{deps: [], body: ok_body(1)}}]})
      end
    end

    test "with nil, true or false as ns, name or alternative name is rejected" do
      for bad <- [nil, true, false] do
        assert_invalid_identity(bad)
        assert_invalid_identity({bad, :a})
        assert_invalid_identity({NsA, bad})
        assert_invalid_rule(%{alts: [{bad, %{deps: [], body: ok_body(1)}}]})
      end
    end

    test "without alts is rejected" do
      assert_invalid_rule(%{})
      assert_invalid_rule(%{dump: fn x -> x end, load: fn x -> x end})
    end

    test "that is not a map is rejected" do
      assert_invalid_rule(alts: [default: %{deps: [], body: ok_body(1)}])
      assert_invalid_rule(nil)
    end

    test "with alts that is not a keyword list is rejected" do
      assert_invalid_rule(%{alts: %{default: %{deps: [], body: ok_body(1)}}})
      assert_invalid_rule(%{alts: [%{deps: [], body: ok_body(1)}]})
    end

    test "with an alternative without deps or without body is rejected" do
      assert_invalid_rule(%{alts: [default: %{body: ok_body(1)}]})
      assert_invalid_rule(%{alts: [default: %{deps: []}]})
      assert_invalid_rule(%{alts: [default: %{}]})
    end

    test "with an unknown key in the rule map or in an alternative map is rejected" do
      assert_invalid_rule(%{alts: [default: %{deps: [], body: ok_body(1)}], other: 1})
      assert_invalid_rule(%{alts: [default: %{deps: [], body: ok_body(1), other: 1}]})
    end

    test "with deps that is not a list is rejected" do
      assert_invalid_rule(%{alts: [default: %{deps: :a, body: ok_body(1)}]})
      assert_invalid_rule(%{alts: [default: %{deps: %{a: :a}, body: ok_body(1)}]})
    end

    test "registers the alternatives of alts in list order" do
      log = start_log()

      alt = fn name, result ->
        {name,
         %{
           deps: [],
           body: fn _, _, _ ->
             track(log, name)
             result
           end
         }}
      end

      wf =
        Workflow.add_rule(Workflow.new(), :a, %{
          alts: [
            alt.(:zed, {:error, :x}),
            alt.(:alpha, {:error, :x}),
            alt.(:mid, {:ok, :done})
          ]
        })

      wf = run!(wf, [:a])

      assert :done == fetch!(wf, :a)
      assert [:zed, :alpha, :mid] == logged(log)
    end
  end

  test "an alternative named :default is tried in its list position like any other" do
    log = start_log()

    wf =
      Workflow.add_rule(Workflow.new(), :a, %{
        alts: [
          first: %{
            deps: [],
            body: fn _, _, _ ->
              track(log, :first)
              {:error, :x}
            end
          },
          default: %{
            deps: [],
            body: fn _, _, _ ->
              track(log, :default)
              {:error, :x}
            end
          },
          last: %{
            deps: [],
            body: fn _, _, _ ->
              track(log, :last)
              {:ok, :last}
            end
          }
        ]
      })

    wf = run!(wf, [:a])

    assert :last == fetch!(wf, :a)
    assert [:first, :default, :last] == logged(log)
  end

  describe "a rule identity" do
    test "name is in the current namespace" do
      wf = Workflow.add_rule(Workflow.new(), :a, const_rule(1))
      wf = run!(wf, [{:default, :a, %{}}])
      assert 1 == fetch!(wf, {:default, :a, %{}})
    end

    test "{ns, name} is in namespace ns" do
      wf = Workflow.add_rule(Workflow.new(), {NsA, :a}, const_rule(1))

      assert {:error,
              %GraphError{rule: nil, reason: {:unknown_rule, {:default, :a, %{}}}}, _} =
               Workflow.run(wf, [:a])

      wf = run!(wf, [{NsA, :a, %{}}])
      assert 1 == fetch!(wf, {NsA, :a, %{}})
    end
  end

  describe "the same rule map registered under two identities" do
    test "is two rules: a key of each is computed and recorded separately" do
      {pid, body} = mock_fun(2, fn _, _, _ -> {:ok, make_ref()} end)
      rule_map = rule([], body)

      wf =
        Workflow.new()
        |> Workflow.add_rule(:one, rule_map)
        |> Workflow.add_rule(:two, rule_map)

      wf = run!(wf, [:one, :two])

      verify(pid)
      assert fetch!(wf, :one) != fetch!(wf, :two)
    end

    test "in two namespaces resolves its dependencies written without namespace in the namespace of each identity" do
      rule_map = rule([:dep], deps_body())

      wf =
        Workflow.new()
        |> Workflow.add_rule({NsA, :r}, rule_map)
        |> Workflow.add_rule({NsB, :r}, rule_map)
        |> Workflow.add_rule({NsA, :dep}, const_rule(:from_a))
        |> Workflow.add_rule({NsB, :dep}, const_rule(:from_b))

      wf = run!(wf, [{NsA, :r, %{}}, {NsB, :r, %{}}])

      assert %{dep: :from_a} == fetch!(wf, {NsA, :r, %{}})
      assert %{dep: :from_b} == fetch!(wf, {NsB, :r, %{}})
    end
  end

  describe "a static dependency" do
    test "naming a rule that is not registered makes run return a graph error before calling any user code" do
      {pid, never} = mock_never(ok_body(1))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:first, rule([], never))
        |> Workflow.add_rule(:a, rule([:missing], ok_body(1)))

      assert {:error, e, wf2} = Workflow.run(wf, [:first, :a])

      assert %GraphError{
               rule: {:default, :a},
               key: nil,
               alternative: :default,
               reason: {:unknown_rule, {:default, :missing, %{}}}
             } = e

      verify(pid)
      assert :error == Workflow.fetch(wf2, :first)
    end

    test "naming a rule that is not registered is a graph error even when no target demands it" do
      {pid, never} = mock_never(ok_body(1))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:first, rule([], never))
        |> Workflow.add_rule(:other, rule([{NsA, :missing, %{}}], ok_body(1)))

      assert {:error, e, _} = Workflow.run(wf, [:first])
      verify(pid)

      assert %GraphError{
               rule: {:default, :other},
               alternative: :default,
               reason: {:unknown_rule, {NsA, :missing, %{}}}
             } = e
    end

    test "with a string ns or name is rejected when the rule is registered" do
      for dep <- ["b", {"b", %{}}, {"Elixir.NsA", :b, %{}}, {NsA, "b", %{}}] do
        assert {:invalid_key, dep} == rejected_dep_reason(dep)
      end
    end

    test "with nil, true or false as ns or name is rejected when the rule is registered" do
      for bad <- [nil, true, false],
          dep <- [bad, {bad, %{}}, {bad, :b, %{}}, {NsA, bad, %{}}] do
        assert {:invalid_key, dep} == rejected_dep_reason(dep)
      end
    end

    test "with params containing a pid, port, reference or function, at any depth, is rejected when the rule is registered" do
      port = Port.open({:spawn, "true"}, [])

      for bad <- [self(), port, make_ref(), fn -> :ok end, &String.upcase/1],
          dep <- [
            {:b, %{x: bad}},
            {NsA, :b, %{x: bad}},
            {:b, %{x: [1, %{"y" => {:ok, bad}}]}},
            {:b, %{bad => 1}}
          ] do
        assert {:invalid_params, dep} == rejected_dep_reason(dep)
      end
    end

    test "written {ns, name} (forgotten params) is rejected as invalid params" do
      e = assert_rejected(rule([{NsA, :b}], ok_body(1)))
      assert {:invalid_params, {NsA, :b}} == e.reason
      assert Exception.message(e) =~ inspect({NsA, :b, %{}})
    end

    test "with params that are not a map is rejected as invalid params" do
      for dep <- [{:b, [id: 1]}, {:b, 1}, {NsA, :b, 1}] do
        assert {:invalid_params, dep} == rejected_dep_reason(dep)
      end
    end

    test "naming a rule registered later in the graph is accepted" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([:b], deps_body()))
        |> Workflow.add_rule(:b, const_rule(1))

      wf = run!(wf, [:a])
      assert %{b: 1} == fetch!(wf, :a)
    end

    test "that is neither a key, an alias map nor a function is rejected" do
      for dep <- [1, [:b], {:a, :b, :c, :d}] do
        assert {:invalid_key, dep} == rejected_dep_reason(dep)
      end
    end
  end

  test "the checks on static dependencies apply to the keys inside a static alias map" do
    for value <- ["b", {NsA, "b", %{}}, nil, 1] do
      assert {:invalid_key, value} == rejected_dep_reason(%{x: value})
    end

    for value <- [{:b, %{p: self()}}, {NsA, :b}, {:b, [id: 1]}] do
      assert {:invalid_params, value} == rejected_dep_reason(%{x: value})
    end
  end

  test "a static alias map whose value is a dependency function is rejected" do
    for fun <- [fn _, _, _ -> :b end, &CompiledNs.account/3] do
      assert {:invalid_key, fun} == rejected_dep_reason(%{x: fun})
    end

    tuple = {CompiledNs, :account, [:base]}
    assert {:invalid_params, tuple} == rejected_dep_reason(%{x: tuple})
  end

  describe "two different static keys of one alternative exposed under the same deps key" do
    test "are rejected under the same alias" do
      b = {:default, :b, %{}}

      assert MapSet.new([{:x, b, :alias}, {:x, {:default, :c, %{}}, :alias}]) ==
               shadowing_exposures(rejected_deps_reason([%{x: :b}, %{x: :c}]))

      assert MapSet.new([{:x, b, :alias}, {:x, {:default, :b, %{id: 1}}, :alias}]) ==
               shadowing_exposures(rejected_deps_reason([%{x: :b}, %{x: {:b, %{id: 1}}}]))
    end

    test "are rejected as shadowing when an alias shadows the written form of another dependency" do
      b = {:default, :b, %{}}
      b1 = {:default, :b, %{id: 1}}
      c = {:default, :c, %{}}
      ns_b = {NsA, :b, %{}}

      for {deps, expected} <- [
            {[:b, %{b: :c}], [{:b, b, :key}, {:b, c, :alias}]},
            {[%{b: :c}, :b], [{:b, b, :key}, {:b, c, :alias}]},
            {[{:b, %{id: 1}}, %{{:b, %{id: 1}} => :c}],
             [{{:b, %{id: 1}}, b1, :key}, {{:b, %{id: 1}}, c, :alias}]},
            {[ns_b, %{ns_b => :c}], [{ns_b, ns_b, :key}, {ns_b, c, :alias}]}
          ] do
        assert MapSet.new(expected) == shadowing_exposures(rejected_deps_reason(deps))
      end
    end
  end

  describe "the same static key listed twice in one alternative is accepted and demanded once" do
    test "in two forms (:a and {ns, :a, %{}}), exposed under each form" do
      {pid, body} = mock_fun(1, ok_body(1))

      wf =
        Workflow.new()
        |> Workflow.add_rule({NsA, :a}, rule([], body))
        |> Workflow.add_rule(
          {NsA, :r},
          rule([:a, {NsA, :a, %{}}, {:a, %{}}], deps_body())
        )

      wf = run!(wf, [{NsA, :r, %{}}])

      verify(pid)
      assert %{:a => 1, {NsA, :a, %{}} => 1, {:a, %{}} => 1} == fetch!(wf, {NsA, :r, %{}})
    end

    test "in two forms in the :default namespace, exposed under each form" do
      {pid, body} = mock_fun(1, ok_body(1))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([], body))
        |> Workflow.add_rule(:r, rule([:a, {:default, :a, %{}}], deps_body()))

      wf = run!(wf, [:r])

      verify(pid)
      assert %{:a => 1, {:default, :a, %{}} => 1} == fetch!(wf, :r)
    end

    test "under the same alias in two alias maps" do
      {pid, body} = mock_fun(1, ok_body(1))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, rule([], body))
        |> Workflow.add_rule(:r, rule([%{x: :a}, %{x: {:a, %{}}}], deps_body()))

      wf = run!(wf, [:r])

      verify(pid)
      assert %{x: 1} == fetch!(wf, :r)
    end
  end

  test "two alternatives of one rule may use the same alias for different keys" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:b, const_rule(:from_b))
      |> Workflow.add_rule(:c, const_rule(:from_c))
      |> Workflow.add_rule(:r, %{
        alts: [
          r1: %{deps: [%{x: :b}], body: error_body()},
          r2: %{deps: [%{x: :c}], body: deps_body()}
        ]
      })

    wf = run!(wf, [:r])
    assert %{x: :from_c} == fetch!(wf, :r)
  end

  test "two alternatives of one rule may declare different dependency lists" do
    wf =
      Workflow.new()
      |> Workflow.add_rule(:b, const_rule(:from_b))
      |> Workflow.add_rule(:c, const_rule(:from_c))
      |> Workflow.add_rule(:d, const_rule(:from_d))
      |> Workflow.add_rule(:r, %{
        alts: [
          r1: %{deps: [:b], body: error_body()},
          r2: %{deps: [:c, :d], body: deps_body()}
        ]
      })

    wf = run!(wf, [:r])
    assert %{c: :from_c, d: :from_d} == fetch!(wf, :r)
  end

  test "two rules with the same name in two namespaces are distinct rules" do
    wf =
      Workflow.new()
      |> Workflow.add_rule({NsA, :r}, const_rule(:a))
      |> Workflow.add_rule({NsB, :r}, const_rule(:b))
      |> Workflow.add_rule(:r, const_rule(:default))

    wf = run!(wf, [{NsA, :r, %{}}, {NsB, :r, %{}}, :r])

    assert :a == fetch!(wf, {NsA, :r, %{}})
    assert :b == fetch!(wf, {NsB, :r, %{}})
    assert :default == fetch!(wf, :r)
  end

  describe "add_ns" do
    test "registers the rules added by its callback in its namespace" do
      wf = Workflow.add_ns(Workflow.new(), NsA, &Workflow.add_rule(&1, :a, const_rule(1)))

      wf = run!(wf, [{NsA, :a, %{}}])
      assert 1 == fetch!(wf, {NsA, :a, %{}})

      assert {:error, %GraphError{reason: {:unknown_rule, {:default, :a, %{}}}}} =
               Workflow.fetch(wf, :a)
    end

    test "resolves the dependencies written without namespace in those rules to its namespace" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, const_rule(:default_b))
        |> Workflow.add_ns(NsA, fn g ->
          g
          |> Workflow.add_rule(:a, rule([:b, {:c, %{id: 1}}], deps_body()))
          |> Workflow.add_rule(:b, const_rule(:ns_b))
          |> Workflow.add_rule(:c, rule([], params_body()))
        end)

      wf = run!(wf, [{NsA, :a, %{}}])
      assert %{:b => :ns_b, {:c, %{id: 1}} => %{id: 1}} == fetch!(wf, {NsA, :a, %{}})
    end

    test "restores the current namespace when the callback returns" do
      wf =
        Workflow.new()
        |> Workflow.add_ns(NsA, &Workflow.add_rule(&1, :a, const_rule(:ns_a)))
        |> Workflow.add_rule(:a, const_rule(:default_a))

      wf = run!(wf, [:a, {NsA, :a, %{}}])
      assert :default_a == fetch!(wf, :a)
      assert :ns_a == fetch!(wf, {NsA, :a, %{}})
    end

    test "raises when the callback does not return a graph" do
      callback = fn _ -> :oops end

      e =
        assert_raise GraphError, fn -> Workflow.add_ns(Workflow.new(), NsA, callback) end

      assert %GraphError{
               rule: nil,
               reason: {:bad_return, :add_ns, ^callback, :oops, :not_a_graph}
             } = e

      callback = fn g -> {:ok, g} end

      e =
        assert_raise GraphError, fn -> Workflow.add_ns(Workflow.new(), NsA, callback) end

      assert {:bad_return, :add_ns, ^callback, {:ok, %Workflow{}}, :not_a_graph} =
               e.reason
    end

    test "raises for a namespace that is not an address" do
      for bad <- ["NsA", nil, true, 1] do
        e = assert_raise GraphError, fn -> Workflow.add_ns(Workflow.new(), bad, & &1) end
        assert %GraphError{rule: nil, reason: {:invalid_namespace, ^bad}} = e
      end
    end
  end

  describe "nested add_ns calls" do
    defp nested_graph do
      Workflow.new()
      |> Workflow.add_ns(NsA, fn g ->
        g
        |> Workflow.add_rule(:before, rule([:leaf], deps_body()))
        |> Workflow.add_ns(NsB, fn g ->
          g
          |> Workflow.add_rule(:inner, rule([:leaf], deps_body()))
          |> Workflow.add_rule(:leaf, const_rule(:leaf_b))
        end)
        |> Workflow.add_rule(:after, rule([:leaf], deps_body()))
        |> Workflow.add_rule(:leaf, const_rule(:leaf_a))
      end)
      |> Workflow.add_rule(:top, rule([:leaf], deps_body()))
      |> Workflow.add_rule(:leaf, const_rule(:leaf_default))
    end

    test "register the rules of the inner callback in the inner namespace" do
      wf = run!(nested_graph(), [{NsB, :inner, %{}}])
      assert %{leaf: :leaf_b} == fetch!(wf, {NsB, :inner, %{}})

      assert {:error, %GraphError{reason: {:unknown_rule, {NsA, :inner, %{}}}}} =
               Workflow.fetch(wf, {NsA, :inner, %{}})
    end

    test "restore the enclosing namespace when the inner callback returns" do
      wf = run!(nested_graph(), [{NsA, :after, %{}}])
      assert %{leaf: :leaf_a} == fetch!(wf, {NsA, :after, %{}})

      assert {:error, %GraphError{reason: {:unknown_rule, {NsB, :after, %{}}}}} =
               Workflow.fetch(wf, {NsB, :after, %{}})

      assert {:error, %GraphError{reason: {:unknown_rule, {:default, :after, %{}}}}} =
               Workflow.fetch(wf, :after)
    end

    test "resolve the dependencies written without namespace to the namespace of each rule" do
      wf =
        run!(nested_graph(), [{NsA, :before, %{}}, {NsB, :inner, %{}}, {NsA, :after, %{}}])

      assert %{leaf: :leaf_a} == fetch!(wf, {NsA, :before, %{}})
      assert %{leaf: :leaf_b} == fetch!(wf, {NsB, :inner, %{}})
      assert %{leaf: :leaf_a} == fetch!(wf, {NsA, :after, %{}})
    end

    test "restore :default once the outermost callback returns" do
      wf = run!(nested_graph(), [:top])
      assert %{leaf: :leaf_default} == fetch!(wf, :top)
    end

    test "accept the same namespace at two levels" do
      wf =
        Workflow.new()
        |> Workflow.add_ns(NsA, fn g ->
          g
          |> Workflow.add_ns(
            NsA,
            &Workflow.add_rule(&1, :inner, rule([:outer], deps_body()))
          )
          |> Workflow.add_rule(:outer, const_rule(:outer))
        end)

      wf = run!(wf, [{NsA, :inner, %{}}])
      assert %{outer: :outer} == fetch!(wf, {NsA, :inner, %{}})
    end
  end

  describe "add_rule with an identity {ns, name} inside an add_ns callback" do
    test "does not change the current namespace" do
      wf =
        Workflow.add_ns(Workflow.new(), NsA, fn g ->
          g
          |> Workflow.add_rule({NsB, :b}, const_rule(:b))
          |> Workflow.add_rule(:a, const_rule(:a))
        end)

      wf = run!(wf, [{NsA, :a, %{}}, {NsB, :b, %{}}])
      assert :a == fetch!(wf, {NsA, :a, %{}})
      assert :b == fetch!(wf, {NsB, :b, %{}})
    end

    test "with :default exposes an entry point" do
      wf =
        Workflow.add_ns(Workflow.new(), Billing, fn g ->
          g
          |> Workflow.add_rule(:account, const_rule(:account))
          |> Workflow.add_rule(
            {:default, :billing},
            rule([{Billing, :account, %{}}], deps_body())
          )
        end)

      wf = run!(wf, [:billing])
      assert %{{Billing, :account, %{}} => :account} == fetch!(wf, :billing)
    end
  end

  test "a graph built with add_ns can be stored in a module attribute" do
    wf = run!(CompiledNs.graph(), [:entry])
    assert {:entry, [:the_account]} == fetch!(wf, :entry)
  end

  describe "an anonymous function or a remote capture of the wrong arity is rejected when the rule is registered" do
    test "as a body or a dependency function (arity 3)" do
      for bad <- [fn -> :ok end, fn _ -> :ok end, fn _, _ -> :ok end, &String.upcase/1] do
        assert_invalid_rule(rule([], bad))
        assert_invalid_rule(rule([bad], ok_body(1)))
      end
    end

    test "as :dump or :load (arity 1)" do
      for bad <- [
            fn -> :ok end,
            fn _, _ -> :ok end,
            &String.upcase/2,
            &CompiledNs.account/3
          ] do
        assert_invalid_rule(Map.put(const_rule(1), :dump, bad))
        assert_invalid_rule(Map.put(const_rule(1), :load, bad))
      end
    end

    test "as a body, a tuple that is not {atom, atom, list} is rejected" do
      assert_invalid_rule(rule([], {CompiledNs, :account}))
      assert_invalid_rule(rule([], {CompiledNs, :account, 10}))
      assert_invalid_rule(rule([], {"Elixir.CompiledNs", :account, []}))
    end
  end

  test "a remote capture naming a function that does not exist yet is accepted when the rule is registered" do
    capture = Function.capture(__MODULE__.NotYet, :body, 3)
    dump = Function.capture(__MODULE__.NotYet, :dump, 1)

    assert %Workflow{} =
             Workflow.add_rule(Workflow.new(), :a, %{
               alts: [default: %{deps: [capture], body: capture}],
               dump: dump,
               load: dump
             })
  end
end
