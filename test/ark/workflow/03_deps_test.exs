defmodule Ark.Workflow.DepsTest do
  use ExUnit.Case, async: true

  import Ark.Test.Mock
  import Ark.Test.WorkflowHelpers

  alias Ark.Workflow

  defmodule NsA do
  end

  defmodule NsB do
  end

  def return_key(_params, _deps, _ctx, key) do
    key
  end

  def return_b(_params, _deps, _ctx) do
    :b
  end

  defp tracked_rule(log, value) do
    rule([], fn params, _, _ ->
      track(log, params)
      {:ok, value}
    end)
  end

  describe "a dependency written" do
    test "name is the rule name of the demanding namespace, params %{}" do
      {pid, body} = mock_fun(1, ok_body(:ns_b))

      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, const_rule(:default_b))
        |> Workflow.add_rule({NsA, :b}, rule([], body))
        |> Workflow.add_rule({NsA, :r}, rule([:b], deps_body()))

      wf = run!(wf, [{NsA, :r, %{}}])

      verify(pid)
      assert [[%{}, _, _]] = calls(pid)
      assert %{b: :ns_b} == fetch!(wf, {NsA, :r, %{}})
    end

    test "{name, params} is the rule name of the demanding namespace" do
      {pid, body} = mock_fun(1, params_body())

      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, const_rule(:default_b))
        |> Workflow.add_rule({NsA, :b}, rule([], body))
        |> Workflow.add_rule({NsA, :r}, rule([{:b, %{id: 1}}], deps_body()))

      wf = run!(wf, [{NsA, :r, %{}}])

      verify(pid)
      assert %{{:b, %{id: 1}} => %{id: 1}} == fetch!(wf, {NsA, :r, %{}})
    end

    test "{ns, name, params} is the rule of namespace ns" do
      wf =
        Workflow.new()
        |> Workflow.add_rule({NsA, :b}, const_rule(:ns_a_b))
        |> Workflow.add_rule({NsB, :b}, rule([], params_body()))
        |> Workflow.add_rule(:b, const_rule(:default_b))
        |> Workflow.add_rule(
          {NsA, :r},
          rule([{NsB, :b, %{id: 1}}, {:default, :b, %{}}], deps_body())
        )

      wf = run!(wf, [{NsA, :r, %{}}])

      assert %{{NsB, :b, %{id: 1}} => %{id: 1}, {:default, :b, %{}} => :default_b} ==
               fetch!(wf, {NsA, :r, %{}})
    end
  end

  describe "the deps map given to a body" do
    test "holds every dependency of the alternative, static and dynamic" do
      wf =
        Enum.reduce([:a, :b, :c, :d, :e, :f], Workflow.new(), fn name, wf ->
          Workflow.add_rule(wf, name, const_rule(name))
        end)

      wf =
        Workflow.add_rule(
          wf,
          :r,
          rule(
            [
              :a,
              fn _, _, _ -> :b end,
              %{x: :c},
              fn _, _, _ -> %{y: :d} end,
              fn _, _, _ -> [:e, {:f, %{}}] end
            ],
            deps_body()
          )
        )

      wf = run!(wf, [:r])

      assert %{:a => :a, :b => :b, :x => :c, :y => :d, :e => :e, {:f, %{}} => :f} ==
               fetch!(wf, :r)
    end

    test "exposes an aliased dependency under its alias, whatever the term used as alias" do
      aliases = ["string", {:tuple, 1}, 1, 2.5, %{k: 1}, [:l], nil, true, :atom, NsA]

      wf =
        Enum.reduce(Enum.with_index(aliases), Workflow.new(), fn {_, i}, wf ->
          Workflow.add_rule(wf, :"k#{i}", const_rule(i))
        end)

      static_map = Map.new(Enum.with_index(aliases), fn {a, i} -> {a, :"k#{i}"} end)

      wf =
        wf
        |> Workflow.add_rule(:static, rule([static_map], deps_body()))
        |> Workflow.add_rule(:dynamic, rule([fn _, _, _ -> static_map end], deps_body()))

      wf = run!(wf, [:static, :dynamic])

      expected = Map.new(Enum.with_index(aliases))
      assert expected == fetch!(wf, :static)
      assert expected == fetch!(wf, :dynamic)
    end

    test "exposes a dependency without alias as name, {name, %{}} or {ns, name, %{}} for the same namespace and empty params" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:a, const_rule(1))
        |> Workflow.add_rule(:r, rule([:a], deps_body()))
        |> Workflow.add_rule(:r2, rule([{:a, %{}}], deps_body()))
        |> Workflow.add_rule(:r3, rule([{:default, :a, %{}}], deps_body()))

      wf = run!(wf, [:r, :r2, :r3])
      assert %{a: 1} == fetch!(wf, :r)
      assert %{{:a, %{}} => 1} == fetch!(wf, :r2)
      assert %{{:default, :a, %{}} => 1} == fetch!(wf, :r3)
    end

    test "exposes a dependency without alias as {name, params} for the same namespace" do
      wf =
        Workflow.new()
        |> Workflow.add_rule({NsA, :a}, rule([], params_body()))
        |> Workflow.add_rule(
          {NsA, :r},
          rule([{NsA, :a, %{id: 1}}, {:a, %{id: 2}}], deps_body())
        )

      wf = run!(wf, [{NsA, :r, %{}}])

      assert %{{:a, %{id: 1}} => %{id: 1}, {:a, %{id: 2}} => %{id: 2}} ==
               fetch!(wf, {NsA, :r, %{}})
    end

    test "exposes a dependency without alias as {ns, name, params} for another namespace" do
      wf =
        Workflow.new()
        |> Workflow.add_rule({NsA, :a}, rule([], params_body()))
        |> Workflow.add_rule(:a, const_rule(:default_a))
        |> Workflow.add_rule(
          {NsB, :r},
          rule([{NsA, :a, %{}}, {:default, :a, %{}}], deps_body())
        )

      wf = run!(wf, [{NsB, :r, %{}}])

      assert %{{NsA, :a, %{}} => %{}, {:default, :a, %{}} => :default_a} ==
               fetch!(wf, {NsB, :r, %{}})
    end

    test "exposes {__MODULE__, :account, %{}} declared in __MODULE__ as written" do
      wf =
        Workflow.new()
        |> Workflow.add_rule({__MODULE__, :account}, const_rule(:acc))
        |> Workflow.add_rule(
          {__MODULE__, :r},
          rule([{__MODULE__, :account, %{}}], deps_body())
        )

      wf = run!(wf, [{__MODULE__, :r, %{}}])
      assert %{{__MODULE__, :account, %{}} => :acc} == fetch!(wf, {__MODULE__, :r, %{}})
    end

    test "exposes {:account, %{}} as written" do
      wf =
        Workflow.new()
        |> Workflow.add_rule({NsA, :account}, const_rule(:acc))
        |> Workflow.add_rule({NsA, :r}, rule([{:account, %{}}], deps_body()))

      wf = run!(wf, [{NsA, :r, %{}}])
      assert %{{:account, %{}} => :acc} == fetch!(wf, {NsA, :r, %{}})
    end

    test "is %{} for an alternative without dependencies" do
      {pid, body} = mock_fun(1, deps_body())
      wf = Workflow.add_rule(Workflow.new(), :r, rule([], body))

      wf = run!(wf, [:r])

      verify(pid)
      assert %{} == fetch!(wf, :r)
    end
  end

  test "the same real key under two aliases of one alternative is computed once and exposed under both aliases" do
    {pid, body} = mock_fun(1, ok_body(1))

    wf =
      Workflow.new()
      |> Workflow.add_rule(:a, rule([], body))
      |> Workflow.add_rule(
        :r,
        rule([%{x: :a, y: {:a, %{}}}, %{z: {:default, :a, %{}}}], deps_body())
      )

    wf = run!(wf, [:r])

    verify(pid)
    assert %{x: 1, y: 1, z: 1} == fetch!(wf, :r)
  end

  describe "the keys of an alias map are demanded in ordered-iterator order" do
    defp check_alias_order(aliases) do
      log = start_log()
      alias_map = Map.new(aliases, fn a -> {a, {:leaf, %{alias: a}}} end)

      wf =
        Workflow.new()
        |> Workflow.add_rule(:leaf, tracked_rule(log, :ok))
        |> Workflow.add_rule(:r, rule([alias_map], deps_body()))

      wf = run!(wf, [:r])

      expected =
        alias_map |> :maps.iterator(:ordered) |> :maps.to_list() |> Enum.map(&elem(&1, 0))

      assert expected == Enum.sort(aliases)
      assert Enum.map(expected, &%{alias: &1}) == logged(log)
      assert map_size(fetch!(wf, :r)) == length(aliases)
    end

    test "for a small map" do
      check_alias_order([:zz, :aa, 3, 1, :mm, 2])
    end

    test "for a map of more than 32 keys" do
      check_alias_order(Enum.map(100..1//-1, &:"alias_#{&1}") ++ Enum.to_list(50..1//-1))
    end
  end

  test "an empty alias map in a static dependency list demands nothing" do
    {pid, body} = mock_fun(1, deps_body())
    wf = Workflow.add_rule(Workflow.new(), :r, rule([%{}], body))

    wf = run!(wf, [:r])

    verify(pid)
    assert %{} == fetch!(wf, :r)
  end

  describe "in a dependency list" do
    test "a {module, function, list} tuple is called as a dependency function" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, const_rule(:vb))
        |> Workflow.add_rule(
          :r,
          rule([{__MODULE__, :return_key, [%{x: :b}]}], deps_body())
        )

      wf = run!(wf, [:r])
      assert %{x: :vb} == fetch!(wf, :r)
    end

    test "a remote capture is called as a dependency function" do
      wf =
        Workflow.new()
        |> Workflow.add_rule(:b, const_rule(:vb))
        |> Workflow.add_rule(:r, rule([&__MODULE__.return_b/3], deps_body()))

      wf = run!(wf, [:r])
      assert %{b: :vb} == fetch!(wf, :r)
    end

    test "a {ns, name, map} tuple is demanded as a key" do
      wf =
        Workflow.new()
        |> Workflow.add_rule({__MODULE__, :return_key}, rule([], params_body()))
        |> Workflow.add_rule(:r, rule([{__MODULE__, :return_key, %{x: :b}}], deps_body()))

      wf = run!(wf, [:r])
      assert %{{__MODULE__, :return_key, %{x: :b}} => %{x: :b}} == fetch!(wf, :r)
    end
  end
end
