defmodule Ark.Workflow do
  @moduledoc ~S"""
  Computes values from rules with ordered fallback alternatives, with a state
  that persists across runs.

  A workflow holds rules. A rule provides a value under a name, and lists one or
  more alternatives to compute that value. Each alternative declares the other
  rules it depends on and a body function. The body receives the values of its
  dependencies and returns `{:ok, value}` or `{:error, reason}`. When an
  alternative fails, the next one is tried. Every computed value and every
  failure is recorded in the workflow, so a key is computed once, and the whole
  state can be dumped to JSON-compatible data and loaded later to resume where
  it stopped.

  Rules are added with `add_rule/3`, using `rule/2` and `alt/2` to build them,
  then `run/3` computes the requested targets and `fetch/2` reads the values:

      iex> import Ark.Workflow, only: [rule: 1, rule: 2]
      iex> wf =
      ...>   Ark.Workflow.new()
      ...>   |> Ark.Workflow.add_rule(:base_price, rule(fn _params, _deps, _ctx -> {:ok, 100} end))
      ...>   |> Ark.Workflow.add_rule(:price, rule([:base_price], fn params, deps, _ctx ->
      ...>     %{discount: discount} = params
      ...>     %{base_price: base_price} = deps
      ...>     {:ok, base_price - discount}
      ...>   end))
      iex> key = {:price, %{discount: 20}}
      iex> {:ok, wf} = Ark.Workflow.run(wf, [key])
      iex> Ark.Workflow.fetch(wf, key)
      {:ok, 80}
      iex> Ark.Workflow.fetch(wf, :base_price)
      {:ok, 100}

  ### Rules, keys and params

  A rule is identified by its name, an atom, within a namespace (see the
  Namespaces section below). Rules added with a bare name belong to the
  `:default` namespace.

  A key designates one value of a rule: the rule name along with a map of
  params. The same rule can provide many values, one per distinct params map.
  Keys are written in three equivalent forms:

  * `:name`, the rule `:name` with empty params.
  * `{:name, params}`, the rule `:name` with the given params.
  * `{namespace, :name, params}`, the full form.

  Params can be any map, including structs and maps with string keys, as long
  as they hold no pid, port, reference or function. Two params maps that are
  not equal designate two keys, so `%{id: 1}` and `%{id: 1.0}` are computed
  separately.

  A body is a function of arity 3, or a `{module, function, extra_args}` tuple.
  It is called with the params of the computed key, the deps map described
  below, and the run context. With a tuple, the extra args are appended after
  those three arguments. The body returns `{:ok, value}` to provide the value.
  Returning `{:error, reason}`, returning anything else, raising, throwing or
  exiting fails the alternative, and the failure is recorded (see Alternatives
  and failures).

  Tuples and remote captures let a workflow be built at compile time and stored
  in a module attribute:

      defmodule MyApp.Pricing do
        alias Ark.Workflow

        @workflow Workflow.new()
                  |> Workflow.add_rule(:base_price, Workflow.rule({__MODULE__, :base_price, []}))
                  |> Workflow.add_rule(:price, Workflow.rule([:base_price], &__MODULE__.price/3))

        def workflow, do: @workflow

        def base_price(_params, _deps, _ctx), do: {:ok, 100}

        def price(%{discount: discount}, %{base_price: base_price}, _ctx) do
          {:ok, base_price - discount}
        end
      end

  ### Dependencies

  An alternative lists its dependencies as keys, in any of the three forms.
  Each dependency is computed before the body is called, and exposed in the
  deps map under the form it was written: `deps.base_price` for `:base_price`,
  `deps[{:base_price, %{currency: "EUR"}}]` for `{:base_price, %{currency:
  "EUR"}}`. A map in the dependencies list is an alias map: each entry exposes
  the key under the given alias.

      Ark.Workflow.alt(
        [:config, %{eur: {:base_price, %{currency: "EUR"}}, usd: {:base_price, %{currency: "USD"}}}],
        fn _params, %{config: config, eur: eur, usd: usd}, _ctx -> {:ok, convert(config, eur, usd)} end
      )

  Dependencies are resolved left to right. When a dependency fails, the
  alternative fails with `{:dep_failed, key}`, and the dependencies to its
  right are left alone.

  A function of arity 3 (or a `{module, function, extra_args}` tuple) in the
  dependencies list is a dependency function. It is called with the params of
  the computed key, the deps map holding the dependencies resolved so far (the
  ones to its left), and the context. It returns the keys to demand: a single
  key, a list of keys, or an alias map. Those keys are computed before the
  entries to its right, and exposed in the deps map like static dependencies.
  Dependency functions let the dependencies of a key depend on its params or
  on values computed earlier:

      Ark.Workflow.alt(
        [:customer, fn _params, %{customer: customer}, _ctx -> %{rate: {:tax_rate, %{country: customer.country}}} end],
        fn _params, %{customer: customer, rate: rate}, _ctx -> {:ok, customer.total * rate} end
      )

  They also express conditional dependencies: returning an empty dependencies
  list or an empty map is valid:

      Ark.Workflow.alt(
        [
          :order,
          fn _params, %{order: order}, _ctx ->
            if order.coupon_code,
              do: %{coupon: {:coupon, %{code: order.coupon_code}}},
              else: %{}
          end
        ],
        fn _params, %{order: order} = deps, _ctx ->
          discount =
            case Map.fetch(deps, :coupon) do
              {:ok, coupon} -> coupon.discount
              :error -> 0
            end

          {:ok, order.total - discount}
        end
      )

  When computing one key, the dependencies of an alternative use each deps map
  name once, across static dependencies and the keys returned by dependency
  functions (a duplicate is tolerated when it exposes the very same key). The
  same key may be exposed under several names, and is computed once. This
  keeps the shape of the deps map stable when a dependency function picks a
  data source: it exposes the best available source under one name and the
  baseline under another, and both are the same key when nothing better is
  available. A duplicate name, a dependency cycle, a dependency on a rule that
  is not registered, or a dependency function returning anything else than
  keys stops the run with an `Ark.Workflow.GraphError`.

  ### Alternatives and failures

  The alternatives of a rule are tried in order. The first one that provides a
  value gives the key its value, and the following ones are left alone. The
  failure of an alternative is recorded under its name, readable with
  `attempts/2`. When every alternative failed, the key is failed with
  `{:all_alternatives_failed, alternative_names}`, and every key depending on
  it fails with `{:dep_failed, key}`, up to the run target. The run then returns
  `{:error, %Ark.Workflow.ComputationError{}, workflow}`, and `blame/2` gathers
  the failure records of every failed key reachable from the target, down to
  the root causes.

      iex> import Ark.Workflow, only: [rule: 1, alt: 1, alt: 2]
      iex> wf =
      ...>   Ark.Workflow.new()
      ...>   |> Ark.Workflow.add_rule(:cached_rate, rule(fn _, _, _ -> {:error, :cache_miss} end))
      ...>   |> Ark.Workflow.add_rule(:rate, rule(
      ...>     cache: alt([:cached_rate], fn _, %{cached_rate: rate}, _ -> {:ok, rate} end),
      ...>     fixed: alt(fn _, _, _ -> {:ok, 0.2} end)
      ...>   ))
      iex> {:ok, wf} = Ark.Workflow.run(wf, [:rate])
      iex> Ark.Workflow.fetch(wf, :rate)
      {:ok, 0.2}
      iex> Ark.Workflow.attempts(wf, :rate)
      %{cache: {:dep_failed, {:default, :cached_rate, %{}}}}
      iex> Ark.Workflow.fetch(wf, :cached_rate)
      {:failed, {:all_alternatives_failed, [:default]}}

  Failures are part of the state. A failed key stays failed on later runs, and
  no user code is called for it, until `clear_failure/2` removes its records.
  Clearing a key also clears the keys that failed because of it, so the next
  run tries them again. A key with a value keeps it, whatever the code of its
  rule becomes.

  Each attempt record holds either `{:dep_failed, key}` or `{:computation_error,
  error}`, where `error` is a map with the following keys:

  * `:kind` - `:user_term` for an `{:error, reason}` return, `:bad_return` for
    any other return value, or `:error`, `:throw` and `:exit` for the
    corresponding exceptions.
  * `:reason` - the returned reason or value, the exception, the thrown term or
    the exit reason.
  * `:message` - a string rendering of the reason, built with
    `Ark.Error.to_string/1`.
  * `:stacktrace` - the formatted stacktrace for exceptions, otherwise `nil`.
  * `:at` - the `DateTime` of the failure.

  ### Namespaces

  Namespaces let a set of rules be defined as a package, with private rules
  that do not clash with the rules of the application or of other packages.
  `add_ns/3` calls a function with the workflow switched to a namespace, so the
  rules it adds with a bare name belong to that namespace. The dependencies a
  rule writes as a bare name or as `{name, params}` resolve in the namespace of
  that rule. A package registers its entry point in the application's
  namespace by naming it explicitly, with `{:default, name}`, and that entry
  point depends on the private rules of the package with full keys:

      defmodule MyApp.Geo do
        alias Ark.Workflow

        def add_rules(wf) do
          Workflow.add_ns(wf, __MODULE__, fn wf ->
            wf
            |> Workflow.add_rule(:client, Workflow.rule(&__MODULE__.client/3))
            |> Workflow.add_rule(:lookup, Workflow.rule([:client], &__MODULE__.lookup/3))
            |> Workflow.add_rule(
              {:default, :coordinates},
              Workflow.rule([%{lookup: {__MODULE__, :lookup, %{}}}], &__MODULE__.coordinates/3)
            )
          end)
        end
      end

      wf = MyApp.Geo.add_rules(Ark.Workflow.new())
      {:ok, wf} = Ark.Workflow.run(wf, [{:coordinates, %{address: "..."}}])

  Any rule can depend on a rule of another namespace with a full key, such as
  `{MyApp.Geo, :lookup, %{}}`. Run targets and the keys given to `fetch/2`,
  `attempts/2`, `blame/2` and `clear_failure/2` are read in the `:default`
  namespace when written as a bare name or `{name, params}`, wherever they are
  called from.

  ### Persistence

  `dump/1` turns the recorded values and failures into a map of strings, lists,
  numbers and maps that encodes to JSON. `load/2` reads that data into a
  workflow holding the rules, and `run/3` resumes from there: keys with a value
  are given to their consumers, failed keys stay failed, and a key whose
  alternatives were partially attempted resumes at the first alternative that
  was not tried.

      {:ok, data} = Ark.Workflow.dump(wf)
      json = Jason.encode!(data)

      # Later, possibly after a deploy
      {:ok, wf} = Ark.Workflow.load(MyApp.Pricing.workflow(), Jason.decode!(json))
      {:ok, wf} = Ark.Workflow.run(wf, targets)

  Params and values made of JSON-compatible terms are stored as they are.
  Other terms, such as atoms, tuples or structs, are stored in External Term
  Format and come back as equal terms. Values holding pids, ports, references or
  functions make `dump/1` return an `Ark.Workflow.CodecError`. A rule provides a
  `:dump` callback that turns its values into persistable terms, and a `:load`
  callback that rebuilds them from the data. The rule is a plain map, so the
  callbacks are merged into the result of `rule/2`:

      Ark.Workflow.add_rule(wf, :conn,
        Ark.Workflow.rule([:config], &MyApp.Db.connect/3)
        |> Map.merge(%{
          dump: fn %MyApp.Db.Conn{url: url} -> url end,
          load: fn url -> MyApp.Db.Conn.reconnect(url) end
        })
      )

  Both callbacks are functions of arity 1 or `{module, function, extra_args}`
  tuples called with the value (or the data) before the extra args.

  Loading never creates atoms. The data must describe rules that are registered
  in the workflow given to `load/2`, and every atom it references must exist in
  the running system. The rules themselves can change between a dump and a
  load: alternatives can be added, removed or reordered, and records stay
  attached to the alternative names, so the current alternative order decides
  what is tried next. A failure record read back from a dump keeps its kind,
  message, stacktrace and time, with its `:reason` set to `nil`.

  ### Context and call wrapper

  The `:context` option of `run/3` is any term given as the third argument to
  every body and dependency function of that run. It carries what the rules
  need from the caller, such as a connection or the current user, and is given
  again to each run.

  The `:call_wrapper` option of `new/1` and `run/3` wraps every call to user
  code. It is a function of arity 3 (or a `{module, function, extra_args}`
  tuple) receiving the kind of the call, `:computation` for a body or `:deps`
  for a dependency function, a meta map with the computed `:key` and the
  `:alternative` name, and the call as `{module, function, args}` or
  `{fun, args}`. The wrapper performs the call with `invoke/1` and returns its
  result, which lets it add logging, telemetry or timeouts around user code:

      Ark.Workflow.new(
        call_wrapper: fn kind, meta, call ->
          Logger.debug("workflow #{kind} for #{inspect(meta.key)}")
          Ark.Workflow.invoke(call)
        end
      )
  """

  alias Ark.Workflow.ClearFailure
  alias Ark.Workflow.ComputationError
  alias Ark.Workflow.GraphError
  alias Ark.Workflow.Persistence
  require Record

  defstruct rules: %{},
            ns: :default,
            call_wrapper: nil,
            store: %{results: %{}, attempts: %{}}

  defguardp is_name(term) when is_atom(term) and term not in [nil, true, false]

  # Represents a rule instance (with params) on the stack in the run loop
  Record.defrecordp(:frame,
    # The rule full key
    key: nil,

    # The remaining alternatives states (:arm records), the head being the one
    # in progress
    arms: []
  )

  # Represents the progress of an alternative within a frame
  Record.defrecordp(:arm,
    # The alternative key
    key: nil,

    # The remaining deps to compute
    deps: [],

    # The deps resolved so far, as dep records by alias. Only used to check
    # that an alias is not exposed for two different keys (shadowing).
    seen: %{},

    # The values of the deps resolved so far, by alias. This is the deps map
    # given to dependency functions and to the body.
    values: %{},

    # The alternative definition
    alt: nil
  )

  # Represents a static dependency of an alternative
  Record.defrecordp(:dep,
    # The name under which the dependency value is exposed in the deps map
    alias: nil,

    # The dependency full key
    key: nil,

    # How the dependency was declared: :key for a bare key (exposed under its
    # own name), :alias for an entry of an alias map
    source: nil
  )

  # Represents a dependency function, resolved to deps at run time
  Record.defrecordp(:dyn,
    # The function or MFA tuple called with the params, the deps map and the
    # context, returning the deps to pull
    callback: nil
  )

  @doc false
  def __ark__(:doc) do
    """
    This module computes values from rules with ordered fallback alternatives,
    dependencies between rules, namespaces, and a state that persists across
    runs.

    ```elixir
    import Ark.Workflow, only: [rule: 1, rule: 2]

    wf =
      Ark.Workflow.new()
      |> Ark.Workflow.add_rule(:config, rule(fn _params, _deps, _ctx -> {:ok, read_config()} end))
      |> Ark.Workflow.add_rule(:report, rule([:config], fn params, %{config: config}, _ctx ->
        {:ok, build_report(config, params.month)}
      end))

    key = {:report, %{month: 11}}
    {:ok, wf} = Ark.Workflow.run(wf, [key])
    {:ok, report} = Ark.Workflow.fetch(wf, key)
    ```
    """
  end

  @doc """
  Returns an empty workflow, with no rules and no recorded state.
  """
  def new do
    new([])
  end

  @doc """
  Returns an empty workflow configured with the given options.

  ### Options

  * `:call_wrapper` - a function of arity 3 or a `{module, function, extra_args}`
    tuple wrapping every call to user code made by `run/3`. See the "Context and
    call wrapper" section of the module documentation. Defaults to `nil`, which
    calls user code directly.

  Raises an `Ark.Opts.Error` for an unknown option or an invalid value.
  """
  def new(opts) do
    opts =
      Ark.Opts.validate!(
        opts,
        %{call_wrapper: nil},
        [subject: "Ark.Workflow.new/1"],
        &validate_new_opt(&1, &2)
      )

    struct(__MODULE__, opts)
  end

  defp validate_new_opt(:call_wrapper, {m, f, args})
       when is_atom(m) and is_atom(f) and is_list(args) do
    {:ok, {m, f, args}}
  end

  defp validate_new_opt(:call_wrapper, fun) when is_function(fun, 3) do
    {:ok, fun}
  end

  defp validate_new_opt(:call_wrapper, nil) do
    {:ok, nil}
  end

  defp validate_new_opt(:call_wrapper, _other) do
    {:error, :invalid_value}
  end

  defp validate_new_opt(_, _) do
    :unknown
  end

  @doc """
  Adds a rule to the workflow.

  The identity is the rule name, an atom, or a `{namespace, name}` tuple. A bare
  name registers the rule in the current namespace: `:default`, or the namespace
  given to `add_ns/3` when called from within its callback.

  The rule is a map with the following keys:

  * `:alts` - a non-empty keyword list of alternatives, tried in order. Each
    alternative is a map with a `:deps` list and a `:body` function. `rule/2`
    and `alt/2` build those maps.
  * `:dump` - optional, a function of arity 1 or a `{module, function,
    extra_args}` tuple turning a value of the rule into persistable terms for
    `dump/1`.
  * `:load` - optional, a function of arity 1 or a `{module, function,
    extra_args}` tuple rebuilding a value of the rule from its dumped data for
    `load/2`.

  Raises an `Ark.Workflow.GraphError` when the identity is invalid, when a rule
  with the same identity is already registered, or when the rule is malformed.
  Dependencies on rules that are not registered yet are accepted, and checked
  by `run/3`.

  ### Examples

      iex> wf = Ark.Workflow.add_rule(Ark.Workflow.new(), :answer, Ark.Workflow.rule(fn _, _, _ -> {:ok, 42} end))
      iex> {:ok, wf} = Ark.Workflow.run(wf, [:answer])
      iex> Ark.Workflow.fetch(wf, :answer)
      {:ok, 42}

  The persistence callbacks are added to the map returned by `rule/2`:

      Ark.Workflow.add_rule(wf, :conn,
        Ark.Workflow.rule([:config], &MyApp.Db.connect/3)
        |> Map.put(:dump, fn %MyApp.Db.Conn{url: url} -> url end)
        |> Map.put(:load, fn url -> MyApp.Db.Conn.reconnect(url) end)
      )
  """
  def add_rule(%__MODULE__{} = wf, identity, rule) do
    identity = normalize_identity!(identity, wf)
    rule = validate_rule!(rule, identity)

    case wf do
      %{rules: %{^identity => _}} ->
        raise GraphError, rule: identity, reason: {:duplicate_rule, identity}

      %{rules: rules} ->
        %{wf | rules: Map.put(rules, identity, rule)}
    end
  end

  @doc """
  Calls the callback with the workflow switched to the given namespace, and
  returns the workflow it returns, switched back to the current namespace.

  Within the callback, `add_rule/3` registers bare names in that namespace. A
  rule for another namespace is registered with a `{namespace, name}` identity,
  typically `{:default, name}` for the entry point of a package of rules. The
  dependencies a rule writes as a bare name or `{name, params}` resolve in the
  namespace of that rule, so the entry point depends on the rules of the
  package with full keys. See the Namespaces section of the module
  documentation.

  The namespace is any atom other than `nil`, `true` and `false`. A module name
  is a good choice.

  Raises an `Ark.Workflow.GraphError` for an invalid namespace, or when the
  callback returns anything else than a workflow.

  ### Examples

      iex> wf =
      ...>   Ark.Workflow.add_ns(Ark.Workflow.new(), MyApp.Geo, fn wf ->
      ...>     wf
      ...>     |> Ark.Workflow.add_rule(:lookup, Ark.Workflow.rule(fn _, _, _ -> {:ok, {48.85, 2.35}} end))
      ...>     |> Ark.Workflow.add_rule({:default, :coordinates}, Ark.Workflow.rule([%{lookup: {MyApp.Geo, :lookup, %{}}}], fn _, %{lookup: xy}, _ -> {:ok, xy} end))
      ...>   end)
      iex> {:ok, wf} = Ark.Workflow.run(wf, [:coordinates])
      iex> Ark.Workflow.fetch(wf, :coordinates)
      {:ok, {48.85, 2.35}}
      iex> Ark.Workflow.fetch(wf, {MyApp.Geo, :lookup, %{}})
      {:ok, {48.85, 2.35}}
  """
  def add_ns(%__MODULE__{}, new_ns, _callback) when not is_name(new_ns) do
    raise GraphError, reason: {:invalid_namespace, new_ns}
  end

  def add_ns(%__MODULE__{} = wf, new_ns, callback) do
    %{ns: current_ns} = wf
    wf = %{wf | ns: new_ns}

    case callback.(wf) do
      %__MODULE__{} = wf ->
        %{wf | ns: current_ns}

      other ->
        raise GraphError, reason: {:bad_return, :add_ns, callback, other, :not_a_graph}
    end
  end

  @doc """
  Builds a rule map for `add_rule/3`.

  Given a keyword list of alternatives built with `alt/2`, returns a rule with
  those alternatives, tried in the list order. Given a body, a function of arity
  3 or a `{module, function, extra_args}` tuple, returns a rule with a single
  alternative named `:default` and no dependencies.

  ### Examples

      iex> Ark.Workflow.rule({MyApp.Rules, :answer, []})
      %{alts: [default: %{deps: [], body: {MyApp.Rules, :answer, []}}]}

      iex> Ark.Workflow.rule(
      ...>   cache: Ark.Workflow.alt([:store], {MyApp.Rules, :from_cache, []}),
      ...>   remote: Ark.Workflow.alt([:client], {MyApp.Rules, :fetch, []})
      ...> )
      %{
        alts: [
          cache: %{deps: [:store], body: {MyApp.Rules, :from_cache, []}},
          remote: %{deps: [:client], body: {MyApp.Rules, :fetch, []}}
        ]
      }
  """
  def rule(alts) when is_list(alts) do
    %{alts: alts}
  end

  def rule(body) do
    rule([], body)
  end

  @doc """
  Builds a rule map with a single alternative named `:default`, for
  `add_rule/3`.

  The dependencies and the body are those of `alt/2`.

  ### Examples

      iex> Ark.Workflow.rule([:config, %{eur: {:rate, %{currency: "EUR"}}}], {MyApp.Rules, :price, []})
      %{
        alts: [
          default: %{
            deps: [:config, %{eur: {:rate, %{currency: "EUR"}}}],
            body: {MyApp.Rules, :price, []}
          }
        ]
      }
  """
  def rule(deps, body) do
    %{alts: [default: alt(deps, body)]}
  end

  @doc """
  Builds an alternative map with no dependencies, for `rule/1`.

  The body is a function of arity 3 or a `{module, function, extra_args}`
  tuple.

  ### Examples

      iex> Ark.Workflow.alt({MyApp.Rules, :answer, []})
      %{deps: [], body: {MyApp.Rules, :answer, []}}
  """
  def alt(body) do
    alt([], body)
  end

  @doc """
  Builds an alternative map, for `rule/1`.

  The dependencies are a list of keys, alias maps and dependency functions, as
  described in the Dependencies section of the module documentation. The body
  is a function of arity 3 or a `{module, function, extra_args}` tuple.

  ### Examples

      iex> Ark.Workflow.alt([:config, {:rate, %{currency: "EUR"}}], {MyApp.Rules, :price, []})
      %{deps: [:config, {:rate, %{currency: "EUR"}}], body: {MyApp.Rules, :price, []}}
  """
  def alt(deps, body) do
    %{deps: deps, body: body}
  end

  defp normalize_identity!({ns, name} = identity, _wf)
       when is_name(ns) and is_name(name) do
    identity
  end

  defp normalize_identity!(name, %{ns: ns}) when is_name(name) do
    {ns, name}
  end

  defp normalize_identity!(other, _wf) do
    raise GraphError, reason: {:invalid_identity, other}
  end

  defp validate_rule!(rule, {ns, _} = identity) when is_map(rule) do
    case Ark.Opts.validate(rule, %{}, [required: [:alts]], &validate_rule_opt(&1, &2, ns)) do
      {:ok, rule} -> rule
      {:error, e} -> raise rule_error(e, identity)
    end
  end

  defp validate_rule!(rule, identity) do
    e = %Ark.Opts.Error{kind: :invalid_value, path: [], value: rule, reason: "a map"}
    raise GraphError, rule: identity, reason: {:invalid_rule, e}
  end

  defp validate_rule_opt(:alts, [_ | _] = alts, ns) do
    with :ok <- validate_alt_names(alts),
         {:ok, by_name} <- Ark.Opts.validate(alts, %{}, &validate_alt(&1, &2, ns)) do
      {:ok, Enum.map(alts, fn {name, _} -> {name, Map.fetch!(by_name, name)} end)}
    end
  end

  defp validate_rule_opt(:alts, _, _ns) do
    {:error, "a non-empty keyword list of alternatives"}
  end

  defp validate_rule_opt(:dump, dump, _ns) do
    validate_callback(dump, 1)
  end

  defp validate_rule_opt(:load, load, _ns) do
    validate_callback(load, 1)
  end

  defp validate_rule_opt(_, _, _ns) do
    :unknown
  end

  defp validate_alt_names([{name, _} | alts]) when is_name(name) do
    validate_alt_names(alts)
  end

  defp validate_alt_names([{name, _} | _]) do
    {:error,
     %Ark.Opts.Error{
       kind: :invalid_value,
       path: [],
       value: name,
       reason: "alternative names as atoms other than nil, true and false"
     }}
  end

  defp validate_alt_names(_) do
    :ok
  end

  defp validate_alt(_name, alt, ns) do
    Ark.Opts.all_of(alt, [&Ark.Opts.map/1, &validate_alt_map(&1, ns)])
  end

  defp validate_alt_map(alt, ns) do
    Ark.Opts.validate(alt, %{}, [required: [:deps, :body]], fn
      :body, body ->
        validate_callback(body, 3)

      :deps, deps ->
        Ark.Opts.all_of(deps, [
          Ark.Opts.list_of(&validate_dep(&1, ns)),
          &validate_exposed_keys/1
        ])

      _, _ ->
        :unknown
    end)
  end

  defp rule_error(%Ark.Opts.Error{path: path} = e, identity) do
    alternative =
      case path do
        [:alts, name | _] -> name
        _ -> nil
      end

    %{graph_error(e) | rule: identity, alternative: alternative}
  end

  defp graph_error(%Ark.Opts.Error{reason: %GraphError{} = e}) do
    e
  end

  defp graph_error(e) do
    %GraphError{reason: {:invalid_rule, e}}
  end

  defp validate_callback(fun, arity) do
    Ark.Opts.any_of(fun, [&Ark.Opts.function(&1, arity), &Ark.Opts.mfa/1])
  end

  defp validate_dep(fun, _ns) when is_function(fun) do
    with {:ok, fun} <- Ark.Opts.function(fun, 3) do
      {:ok, [dyn(callback: fun)]}
    end
  end

  defp validate_dep({m, f, args} = mfa, _ns)
       when is_atom(m) and is_atom(f) and is_list(args) do
    {:ok, [dyn(callback: mfa)]}
  end

  defp validate_dep(entry, ns) do
    with {:error, reason} <- parse_dep(entry, ns) do
      {:error, %GraphError{reason: reason}}
    end
  end

  defp validate_exposed_keys(entries) do
    deps = entries |> Enum.concat() |> Enum.uniq()

    exposed =
      for dep(alias: alias_name, key: key, source: source) <- deps do
        {alias_name, key, source}
      end

    with :ok <- check_exposed_keys(exposed, %{}) do
      {:ok, deps}
    end
  end

  defp check_exposed_keys([{exposed, key, source} | rest], seen) do
    case seen do
      %{^exposed => {^key, _}} ->
        check_exposed_keys(rest, seen)

      %{^exposed => {seen_key, seen_source}} ->
        shadowing = {:shadowing, {exposed, seen_key, seen_source}, {exposed, key, source}}
        {:error, %GraphError{reason: shadowing}}

      _ ->
        check_exposed_keys(rest, Map.put(seen, exposed, {key, source}))
    end
  end

  defp check_exposed_keys([], _seen) do
    :ok
  end

  defp parse_dep(aliases, ns) when is_map(aliases) and not is_struct(aliases) do
    aliases
    |> :maps.iterator(:ordered)
    |> :maps.to_list()
    |> Ark.Ok.map_ok(fn {alias_name, key} ->
      with {:ok, full_key} <- parse_key(key, ns) do
        {:ok, dep(alias: alias_name, key: full_key, source: :alias)}
      end
    end)
  end

  defp parse_dep(key, ns) do
    with {:ok, dep} <- parse_key_dep(key, ns) do
      {:ok, [dep]}
    end
  end

  defp parse_key_dep(key, ns) do
    with {:ok, full_key} <- parse_key(key, ns) do
      {:ok, dep(alias: key, key: full_key, source: :key)}
    end
  end

  defp parse_returned_deps(keys, ns) when is_list(keys) do
    if proper_list?(keys) do
      Ark.Ok.map_ok(keys, &parse_key_dep(&1, ns))
    else
      {:error, {:invalid_key, keys}}
    end
  end

  defp parse_returned_deps(value, ns) do
    parse_dep(value, ns)
  end

  defp proper_list?([_ | tail]) do
    proper_list?(tail)
  end

  defp proper_list?([]) do
    true
  end

  defp proper_list?(_) do
    false
  end

  defp parse_key(name, ns) when is_atom(name) do
    if is_name(name) do
      {:ok, {ns, name, %{}}}
    else
      {:error, {:invalid_key, name}}
    end
  end

  defp parse_key({name, params} = given, ns) when is_name(name) do
    if valid_params?(params) do
      {:ok, {ns, name, params}}
    else
      {:error, {:invalid_params, given}}
    end
  end

  defp parse_key({key_ns, name, params} = given, _ns)
       when is_name(key_ns) and is_name(name) do
    if valid_params?(params) do
      {:ok, {key_ns, name, params}}
    else
      {:error, {:invalid_params, given}}
    end
  end

  defp parse_key(given, _ns) do
    {:error, {:invalid_key, given}}
  end

  defp valid_params?(params) when is_map(params) do
    valid_param_term?(params)
  end

  defp valid_params?(_) do
    false
  end

  defp valid_param_term?(term)
       when is_pid(term) or is_port(term) or is_reference(term) or is_function(term) do
    false
  end

  defp valid_param_term?(map) when is_map(map) do
    valid_param_term?(:maps.to_list(map))
  end

  defp valid_param_term?(tuple) when is_tuple(tuple) do
    valid_param_term?(Tuple.to_list(tuple))
  end

  defp valid_param_term?([head | tail]) do
    valid_param_term?(head) and valid_param_term?(tail)
  end

  defp valid_param_term?(_) do
    true
  end

  defp rule_key({ns, name, _params}) do
    {ns, name}
  end

  defp rule_of(full_key, %{rules: rules}) do
    Map.fetch(rules, rule_key(full_key))
  end

  defp read_key!(key) do
    case parse_key(key, :default) do
      {:ok, full_key} -> full_key
      {:error, reason} -> raise GraphError, reason: reason
    end
  end

  @doc """
  Computes the given target keys and returns the workflow with the recorded
  values and failures.

  Targets are keys in any of the three forms, read in the `:default` namespace
  when written as a bare name or `{name, params}`. They are computed in order,
  along with the keys they depend on. Keys that already have a value or a
  failure are left as they are, so running a workflow twice calls no user code
  the second time.

  Returns `{:ok, workflow}` when every target has a value. Returns
  `{:error, %Ark.Workflow.ComputationError{}, workflow}` when a target fails,
  naming the first failed target. The returned workflow holds every fact
  recorded until then, and `blame/2` gives the failure records of the target.
  Returns `{:error, %Ark.Workflow.GraphError{}, workflow}` for a target with no
  registered rule, a dependency on a rule that is not registered, a dependency
  cycle, or a dependency function returning anything else than keys.

  ### Options

  * `:context` - any term, given as the third argument to every body and
    dependency function of this run. Defaults to `%{}`.
  * `:call_wrapper` - replaces the call wrapper given to `new/1` for this run.
    `nil` calls user code directly.

  Raises an `Ark.Opts.Error` for an unknown option or an invalid value.

  ### Examples

      iex> import Ark.Workflow, only: [rule: 1, rule: 2]
      iex> wf =
      ...>   Ark.Workflow.new()
      ...>   |> Ark.Workflow.add_rule(:user, rule(fn %{id: id}, _deps, ctx -> {:ok, Map.fetch!(ctx.users, id)} end))
      ...>   |> Ark.Workflow.add_rule(:greeting, rule([%{user: {:user, %{id: 1}}}], fn _params, %{user: user}, _ctx -> {:ok, "Hello " <> user} end))
      iex> {:ok, wf} = Ark.Workflow.run(wf, [:greeting], context: %{users: %{1 => "Alice"}})
      iex> Ark.Workflow.fetch(wf, :greeting)
      {:ok, "Hello Alice"}
      iex> Ark.Workflow.fetch(wf, {:user, %{id: 1}})
      {:ok, "Alice"}
  """
  def run(%__MODULE__{} = wf, targets, opts \\ []) when is_list(targets) do
    %{store: store, rules: rules} = wf

    opts =
      Ark.Opts.validate!(
        opts,
        %{call_wrapper: wf.call_wrapper, context: %{}},
        [subject: "Ark.Workflow.run/3"],
        &validate_run_opt(&1, &2)
      )

    state = %{
      rules: rules,
      ctx: opts.context,
      store: store,
      stack: [],
      call_wrapper: opts.call_wrapper,
      stack_index: %{}
    }

    keys = prerun_check!(wf, targets, state)

    case run_targets(keys, state) do
      {:ok, state} ->
        {:ok, %{wf | store: state.store}}

      {:failed, key, state} ->
        ce = %ComputationError{target: key}
        {:error, ce, %{wf | store: state.store}}
    end
  catch
    {:stop_run, e, state} -> {:error, e, %{wf | store: state.store}}
  end

  defp validate_run_opt(:context, term) do
    {:ok, term}
  end

  defp validate_run_opt(k, v) when k in [:call_wrapper] do
    validate_new_opt(k, v)
  end

  defp validate_run_opt(_, _) do
    :unknown
  end

  defp prerun_check!(wf, targets, state) do
    keys = Enum.map(targets, &prerun_check_target!(&1, wf, state))
    Enum.each(wf.rules, &prerun_check_rule_deps!(&1, state))
    keys
  end

  defp prerun_check_target!(target, wf, state) do
    case parse_key(target, :default) do
      {:ok, key} ->
        if is_map_key(wf.rules, rule_key(key)) do
          key
        else
          throw({:stop_run, %GraphError{reason: {:unknown_rule, key}}, state})
        end

      {:error, reason} ->
        throw({:stop_run, %GraphError{reason: reason}, state})
    end
  end

  defp prerun_check_rule_deps!({rule_key, rule}, state) do
    Enum.each(rule.alts, fn {ak, %{deps: deps}} ->
      Enum.each(deps, &check_dep!(&1, rule_key, ak, state))
    end)
  end

  defp check_dep!(dep, rule_key, ak, state) do
    with {:error, reason} <- check_known_rule(dep, state) do
      e = %GraphError{rule: rule_key, alternative: ak, reason: reason}
      throw({:stop_run, e, state})
    end
  end

  defp check_known_rule(dep(key: key) = dep, %{rules: rules}) do
    if Map.has_key?(rules, rule_key(key)) do
      {:ok, dep}
    else
      {:error, {:unknown_rule, key}}
    end
  end

  defp check_known_rule(dyn() = dyn, _wf) do
    {:ok, dyn}
  end

  defp run_targets([key | keys] = all_keys, state) do
    # Check if target already ran from a previous run() call
    case state.store.results do
      %{^key => {:ok, _}} ->
        run_targets(keys, state)

      %{^key => {:failed, _}} ->
        {:failed, key, state}

      _ ->
        {:ok, state} = run_loop(push_frame(state, key))

        # running with the same target again to return from :failed from this
        # function if it failed and so skip computing other targets.
        run_targets(all_keys, state)
    end
  end

  defp run_targets([], state) do
    {:ok, state}
  end

  defp run_loop(
         %{stack: [frame(key: key, arms: [arm(key: alt_key) = arm | _]) | _]} = state
       ) do
    meta = %{key: key, alternative: alt_key}

    case pull_deps(arm, meta, state) do
      {:needy, arm(deps: [dep(key: dep_key) | _]) = arm} ->
        state |> replace_arm(arm) |> push_frame(dep_key) |> run_loop()

      {:ready, arm} ->
        case call_arm(arm, meta, state) do
          {:ok, value} ->
            state |> put_result(key, {:ok, value}) |> pop_frame() |> run_loop()

          {:failed, record} ->
            state |> put_attempt(key, alt_key, record) |> drop_arm() |> run_loop()
        end

      {:failed, record} ->
        state |> put_attempt(key, alt_key, record) |> drop_arm() |> run_loop()

      {:error, :graph, reason} ->
        e = %GraphError{
          rule: rule_key(key),
          key: key,
          alternative: alt_key,
          reason: reason
        }

        throw({:stop_run, e, state})
    end
  end

  # No more arms to this frame
  defp run_loop(%{stack: [frame(key: key, arms: []) | _]} = state) do
    {:ok, rule} = rule_of(key, state)
    attempted = Map.get(state.store.attempts, key, %{})

    failed =
      for {alt_key, _} <- rule.alts, is_map_key(attempted, alt_key) do
        alt_key
      end

    state = put_result(state, key, {:failed, {:all_alternatives_failed, failed}})
    run_loop(pop_frame(state))
  end

  defp run_loop(%{stack: []} = state) do
    {:ok, state}
  end

  defp new_frame(full_key, state) do
    attempted = Map.get(state.store.attempts, full_key, %{})

    case rule_of(full_key, state) do
      {:ok, rule} ->
        frame(
          key: full_key,
          arms:
            for {key, alt} <- rule.alts, not is_map_key(attempted, key) do
              %{deps: deps} = alt
              arm(key: key, deps: deps, alt: alt)
            end
        )

      :error ->
        throw({:stop_run, %GraphError{reason: {:unknown_rule, full_key}}, state})
    end
  end

  defp push_frame(%{stack_index: index} = state, full_key)
       when is_map_key(index, full_key) do
    [frame(key: key, arms: [arm(key: alt_key) | _]) | _] = state.stack
    stack_keys = :lists.reverse(Enum.map(state.stack, fn frame(key: k) -> k end))

    e = %GraphError{
      rule: rule_key(key),
      key: key,
      alternative: alt_key,
      reason: {:cycle, full_key, stack_keys}
    }

    throw({:stop_run, e, state})
  end

  defp push_frame(state, full_key) do
    %{stack: stack, stack_index: index} = state
    frame = new_frame(full_key, state)
    %{state | stack: [frame | stack], stack_index: Map.put(index, full_key, true)}
  end

  defp pop_frame(%{stack: [frame(key: key) | stack], stack_index: index} = state) do
    %{state | stack: stack, stack_index: Map.delete(index, key)}
  end

  defp drop_arm(%{stack: [frame(arms: [_ | arms]) = frame | frames]} = state) do
    %{state | stack: [frame(frame, arms: arms) | frames]}
  end

  defp replace_arm(%{stack: [frame(arms: [_ | arms]) = frame | frames]} = state, arm) do
    %{state | stack: [frame(frame, arms: [arm | arms]) | frames]}
  end

  defp pull_deps(arm(deps: deps) = arm, meta, state) do
    case do_pull_deps(deps, arm, meta, state) do
      {:ok, arm(deps: []) = arm} -> {:ready, arm}
      {:ok, arm} -> {:needy, arm}
      err -> err
    end
  end

  defp do_pull_deps(
         [dep(alias: alias_name, key: full_key, source: source) = dep | deps],
         arm(seen: seen) = arm,
         meta,
         state
       ) do
    case seen do
      %{^alias_name => dep(key: ^full_key)} ->
        do_pull_deps(deps, arm, meta, state)

      %{^alias_name => dep(key: seen_key, source: seen_source)} ->
        {:error, :graph,
         {:shadowing, {alias_name, seen_key, seen_source}, {alias_name, full_key, source}}}

      _ ->
        pull_dep(dep, deps, arm, meta, state)
    end
  end

  defp do_pull_deps([dyn(callback: fun) | deps], arm(values: values) = arm, meta, state) do
    case call_dep(fun, values, meta, state) do
      {:ok, new_deps} -> do_pull_deps(new_deps ++ deps, arm, meta, state)
      err -> err
    end
  end

  defp do_pull_deps([], arm, _meta, _state) do
    {:ok, arm(arm, deps: [])}
  end

  defp pull_dep(dep(alias: alias_name, key: full_key) = dep, deps, arm, meta, state) do
    case state.store.results do
      %{^full_key => {:ok, value}} ->
        arm(seen: seen, values: values) = arm

        arm =
          arm(arm,
            seen: Map.put(seen, alias_name, dep),
            values: Map.put(values, alias_name, value)
          )

        do_pull_deps(deps, arm, meta, state)

      %{^full_key => {:failed, _}} ->
        {:failed, {:dep_failed, full_key}}

      _ ->
        {:ok, arm(arm, deps: [dep | deps])}
    end
  end

  defp call_arm(arm, meta, state) do
    arm(values: values, alt: %{body: body}) = arm
    {_, _, params} = meta.key
    call = build_call(body, params, values, state.ctx)

    case call_impl(:computation, meta, call, state) do
      {:returned, {:ok, v}} ->
        {:ok, v}

      {:returned, {:error, reason}} ->
        {:failed, computation_error(:user_term, reason, nil)}

      {:returned, other} ->
        {:failed, computation_error(:bad_return, other, nil)}

      {:caught, kind, e, stacktrace} ->
        {:failed, computation_error(kind, e, stacktrace)}
    end
  end

  defp call_dep(fun, acc, meta, state) do
    %{ctx: ctx} = state
    {ns, _, params} = meta.key
    call = build_call(fun, params, acc, ctx)

    case call_impl(:deps, meta, call, state) do
      {:caught, kind, e, stacktrace} ->
        {:failed, computation_error(kind, e, stacktrace)}

      {:returned, value} ->
        with {:ok, new_deps} <- parse_returned_deps(value, ns),
             {:ok, new_deps} <- Ark.Ok.map_ok(new_deps, &check_known_rule(&1, state)) do
          {:ok, Enum.uniq(new_deps)}
        else
          {:error, reason} ->
            {:error, :graph, {:bad_return, :deps, fun, value, reason}}
        end
    end
  end

  defp call_impl(kind, meta, call, state) do
    %{call_wrapper: call_wrapper} = state

    {:returned, call_wrapped(call_wrapper, kind, meta, call)}
  rescue
    e -> {:caught, :error, e, __STACKTRACE__}
  catch
    kind, e -> {:caught, kind, e, __STACKTRACE__}
  end

  defp call_wrapped(nil, _kind, _meta, call) do
    invoke(call)
  end

  defp call_wrapped({m, f, a}, kind, meta, call) do
    apply(m, f, [kind, meta, call | a])
  end

  defp call_wrapped(fun, kind, meta, call) do
    fun.(kind, meta, call)
  end

  defp build_call({m, f, a}, params, acc, ctx) do
    {m, f, [params, acc, ctx | a]}
  end

  defp build_call(fun, params, acc, ctx) do
    {fun, [params, acc, ctx]}
  end

  @doc """
  Performs a call received by a call wrapper and returns its result.

  The call is `{module, function, args}` or `{fun, args}`, as given to the
  wrapper. Raises, throws and exits of the user code go through, and are
  recorded as failures by `run/3`. A wrapper may change the arguments before
  invoking the call, for instance to extend the context.

  This function is a stable contract: it applies the function to the arguments
  with `Kernel.apply/3` or `Kernel.apply/2`, and will stay that thin. A wrapper
  is free to inspect the call and perform it by itself, for instance to run it
  in a task or under a timeout.

  ### Examples

      iex> Ark.Workflow.invoke({Enum, :sum, [[1, 2, 3]]})
      6
      iex> Ark.Workflow.invoke({fn a, b -> a + b end, [1, 2]})
      3
  """
  def invoke({m, f, args}) do
    apply(m, f, args)
  end

  def invoke({fun, args}) when is_function(fun) do
    apply(fun, args)
  end

  defp put_result(%{store: store} = state, key, result) do
    %{state | store: %{store | results: Map.put(store.results, key, result)}}
  end

  defp put_attempt(%{store: store} = state, key, alt_key, record) do
    attempts =
      Map.update(store.attempts, key, %{alt_key => record}, &Map.put(&1, alt_key, record))

    %{state | store: %{store | attempts: attempts}}
  end

  defp computation_error(kind, reason, stacktrace) do
    {:computation_error,
     %{
       at: DateTime.utc_now(),
       kind: kind,
       stacktrace: format_stacktrace(stacktrace),
       reason: reason,
       message: Ark.Error.to_string(reason)
     }}
  end

  defp format_stacktrace(stacktrace) when is_list(stacktrace) do
    stacktrace
    |> Enum.map(fn
      {m, f, args, loc} when is_list(args) -> {m, f, length(args), loc}
      entry -> entry
    end)
    |> Exception.format_stacktrace()
  end

  defp format_stacktrace(nil) do
    nil
  end

  @doc """
  Returns the recorded result of a key.

  Returns `{:ok, value}` for a key with a value, `{:failed,
  {:all_alternatives_failed, alternative_names}}` for a failed key, and
  `:error` for a key with no recorded result. The attempt records of a failed
  key are read with `attempts/2`.

  The key is read in the `:default` namespace when written as a bare name or
  `{name, params}`. Raises an `Ark.Workflow.GraphError` for a malformed key.
  """
  def fetch(%__MODULE__{} = wf, key) do
    full_key = read_key!(key)

    case wf.store.results do
      %{^full_key => result} -> result
      _ -> :error
    end
  end

  @doc """
  Returns the failure records of the attempted alternatives of a key, by
  alternative name.

  Each record is `{:dep_failed, dependency_key}` or `{:computation_error,
  error}`, as described in the "Alternatives and failures" section of the
  module documentation. Returns an empty map for a key with no attempt.

  The key is read in the `:default` namespace when written as a bare name or
  `{name, params}`. Raises an `Ark.Workflow.GraphError` for a malformed key.
  """
  def attempts(%__MODULE__{} = wf, key) do
    Map.get(wf.store.attempts, read_key!(key), %{})
  end

  @doc """
  Returns the failure records of every failed key reachable from a failed key,
  down to the root causes.

  Returns `{:ok, records}` where `records` maps each failed key, in the full
  `{namespace, name, params}` form, to its attempts as returned by
  `attempts/2`. The map holds the given key, the keys its alternatives failed
  on with `{:dep_failed, _}`, and so on transitively. Returns `{:error,
  :not_failed}` for a key with a value or with no recorded result.

  The key is read in the `:default` namespace when written as a bare name or
  `{name, params}`. Raises an `Ark.Workflow.GraphError` for a malformed key.

  ### Examples

      iex> import Ark.Workflow, only: [rule: 1, rule: 2]
      iex> wf =
      ...>   Ark.Workflow.new()
      ...>   |> Ark.Workflow.add_rule(:token, rule(fn _, _, _ -> {:error, :unauthorized} end))
      ...>   |> Ark.Workflow.add_rule(:profile, rule([:token], fn _, _, _ -> {:ok, :unreachable} end))
      iex> {:error, %Ark.Workflow.ComputationError{target: {:default, :profile, %{}}}, wf} = Ark.Workflow.run(wf, [:profile])
      iex> {:ok, blame} = Ark.Workflow.blame(wf, :profile)
      iex> blame[{:default, :profile, %{}}]
      %{default: {:dep_failed, {:default, :token, %{}}}}
      iex> %{default: {:computation_error, %{kind: :user_term, reason: :unauthorized}}} = blame[{:default, :token, %{}}]
  """
  def blame(%__MODULE__{} = wf, key) do
    full_key = read_key!(key)

    case wf.store.results do
      %{^full_key => {:failed, _}} -> {:ok, collect_blame(wf.store, [full_key], %{})}
      _ -> {:error, :not_failed}
    end
  end

  defp collect_blame(store, [full_key | keys], acc) when is_map_key(acc, full_key) do
    collect_blame(store, keys, acc)
  end

  defp collect_blame(store, [full_key | keys], acc) do
    case store.results do
      %{^full_key => {:failed, _}} ->
        attempts = Map.get(store.attempts, full_key, %{})

        deps =
          for {_alt, {:dep_failed, dep_key}} <- attempts do
            dep_key
          end

        collect_blame(store, deps ++ keys, Map.put(acc, full_key, attempts))

      _ ->
        collect_blame(store, keys, acc)
    end
  end

  defp collect_blame(_store, [], acc) do
    acc
  end

  @doc """
  Removes the failure of a key, so the next run tries its alternatives again.

  Given a key, clears that key. Given a function of arity 1, clears every
  failed key for which it returns a truthy value. The function receives keys in
  the full `{namespace, name, params}` form.

  Clearing a key removes its failed result and all its attempt records. The
  keys that failed because of it, holding a `{:dep_failed, key}` record, lose
  that record and their failure, transitively, while their other attempt
  records are kept. Recorded values are kept.

  Returns `{:ok, workflow}`, or `{:error, :not_failed}` when the key is not
  failed or when the function selects no key.

  The key is read in the `:default` namespace when written as a bare name or
  `{name, params}`. Raises an `Ark.Workflow.GraphError` for a malformed key or
  a key with no registered rule.

  ### Examples

      iex> import Ark.Workflow, only: [rule: 1]
      iex> wf = Ark.Workflow.add_rule(Ark.Workflow.new(), :flaky, rule(fn _, _, ctx -> ctx end))
      iex> {:error, _, wf} = Ark.Workflow.run(wf, [:flaky], context: {:error, :timeout})
      iex> {:ok, wf} = Ark.Workflow.clear_failure(wf, :flaky)
      iex> {:ok, wf} = Ark.Workflow.run(wf, [:flaky], context: {:ok, :done})
      iex> Ark.Workflow.fetch(wf, :flaky)
      {:ok, :done}
  """
  def clear_failure(%__MODULE__{} = wf, pred) when is_function(pred, 1) do
    roots =
      for {k, {:failed, _}} <- wf.store.results, pred.(k) do
        k
      end

    clear_roots(wf, roots)
  end

  def clear_failure(%__MODULE__{} = wf, key) do
    full_key = read_key!(key)

    if not is_map_key(wf.rules, rule_key(full_key)) do
      raise GraphError, reason: {:unknown_rule, full_key}
    end

    case wf.store.results do
      %{^full_key => {:failed, _}} -> clear_roots(wf, [full_key])
      _ -> {:error, :not_failed}
    end
  end

  defp clear_roots(_wf, []) do
    {:error, :not_failed}
  end

  defp clear_roots(wf, roots) do
    {:ok, %{wf | store: ClearFailure.clear(wf.store, roots)}}
  end

  @doc """
  Returns the recorded values and failures of the workflow as data that
  encodes to JSON.

  The data is a map of strings, numbers, lists and maps with string keys,
  deterministic for a given state. Values of a rule declaring a `:dump`
  callback go through it first. See the Persistence section of the module
  documentation.

  Returns `{:ok, data}`, or `{:error, %Ark.Workflow.CodecError{}}` when a value
  holds a pid, port, reference or function, or when a `:dump` callback fails.

  ### Examples

      iex> import Ark.Workflow, only: [rule: 1]
      iex> wf = Ark.Workflow.add_rule(Ark.Workflow.new(), :answer, rule(fn _, _, _ -> {:ok, 42} end))
      iex> {:ok, wf} = Ark.Workflow.run(wf, [:answer])
      iex> {:ok, data} = Ark.Workflow.dump(wf)
      iex> deployed = Ark.Workflow.add_rule(Ark.Workflow.new(), :answer, rule(fn _, _, _ -> raise "never called" end))
      iex> {:ok, wf} = Ark.Workflow.load(deployed, data)
      iex> Ark.Workflow.fetch(wf, :answer)
      {:ok, 42}
  """
  def dump(%__MODULE__{} = wf) do
    Persistence.dump(wf.rules, wf.store)
  end

  @doc """
  Replaces the recorded state of the workflow with the state read from data
  produced by `dump/1`.

  The workflow must hold a rule for every key the data describes. Values of a
  rule declaring a `:load` callback go through it. Loading never creates atoms:
  every atom the data references must exist in the running system. See the
  Persistence section of the module documentation.

  Returns `{:ok, workflow}`, or `{:error, %Ark.Workflow.CodecError{}}` for
  malformed data, data describing rules that are not registered, atoms that do
  not exist, or a `:load` callback that fails.
  """
  def load(%__MODULE__{} = wf, data) do
    with {:ok, store} <- Persistence.load(wf.rules, data) do
      {:ok, %{wf | store: store}}
    end
  end
end
