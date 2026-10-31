defmodule Ark.Workflow do
  alias Ark.Workflow.ComputationError
  alias Ark.Workflow.GraphError
  require Record

  defstruct rules: %{},
            default_ns: :default,
            stack: [],
            store: %{results: %{}, attempts: %{}},
            ctx: %{}

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

    # An accumulator of computed deps
    acc: %{},

    # The alternative definition
    alt: nil
  )

  # Represents a static dependency of an alternative
  Record.defrecordp(:dep,
    # The name under which the dependency value is exposed in the accumulator
    alias: nil,

    # The dependency full key
    key: nil,

    # How the dependency was declared: :key for a bare key (exposed under its
    # own name), :alias for an entry of an alias map
    source: nil
  )

  # Represents a dependency function, resolved to deps at run time
  Record.defrecordp(:dyn,
    # The function or MFA tuple called with the params, the accumulator and the
    # context, returning the deps to pull
    callback: nil
  )

  def new do
    new([])
  end

  def new([]) do
    %__MODULE__{}
  end

  def add_rule(%__MODULE__{} = wf, identity, rule) do
    {ns, _} = identity = normalize_identity!(identity, wf)
    rule = rule |> validate_rule!(identity) |> normalize_rule(ns)

    case wf do
      %{rules: %{^identity => _}} ->
        raise GraphError, rule: identity, reason: {:duplicate_rule, identity}

      %{rules: rules} ->
        %{wf | rules: Map.put(rules, identity, rule)}
    end
  end

  def add_ns(%__MODULE__{} = wf, new_ns, callback) when not is_name(new_ns) do
    raise GraphError, reason: {:invalid_namespace, new_ns}
  end

  def add_ns(%__MODULE__{} = wf, new_ns, callback) do
    %{default_ns: current_ns} = wf
    wf = %{wf | default_ns: new_ns}

    case callback.(wf) do
      %__MODULE__{} = wf ->
        %{wf | default_ns: current_ns}

      other ->
        raise GraphError, reason: {:bad_return, :add_ns, callback, other, :not_a_graph}
    end
  end

  def run(wf, targets, opts \\ []) do
    prerun_check!(wf, targets)
    %{stack: stack, store: store, default_ns: default_ns} = wf

    case run_targets(targets, store, wf) do
      {:ok, store} ->
        {:ok, %{wf | stack: [], store: store}}

      {:failed, key, store} ->
        ce = %ComputationError{target: key, causes: :foo}
        {:error, ce, %{wf | stack: [], store: store}}
    end
  catch
    {:stop_run, e, wf} -> {:error, e, wf}
  end

  defp run_targets([target | targets] = all_targets, store, wf) do
    key = full_key(target, wf.default_ns)

    # Check if target already ran from a previous run() call
    case store.results do
      %{^key => {:ok, _}} ->
        run_targets(targets, store, wf)

      %{^key => {:failed, _}} ->
        {:failed, key, store}

      _ ->
        {:ok, [], store} = run_loop([new_frame(key, store, wf)], store, wf)

        # running with the same target again to return from :failed from this
        # function if it failed and so skip computing other targets.
        run_targets(all_targets, store, wf)
    end
  end

  defp run_targets([], store, _wf) do
    {:ok, store}
  end

  def fetch(%__MODULE__{} = wf, key) do
    case normalize_key(key, wf.default_ns) do
      {:ok, fk} -> fetch_result(wf, fk)
      {:error, reason} -> {:error, %GraphError{reason: reason}}
    end
  end

  # TODO this should not be a graph error, and the double :error vs {:error,
  # _} is not great
  defp fetch_result(wf, fk) do
    {ns, name, _} = fk

    case Map.fetch(wf.store.results, fk) do
      {:ok, result_tuple} -> result_tuple
      :error when is_map_key(wf.rules, {ns, name}) -> :error
      :error -> {:error, %GraphError{reason: {:unknown_rule, fk}}}
    end
  end

  # TODO we need to normalize the API function names. "attempts" should return
  # raw value. Since we return a result tuple, it should be fetch_attempts (and
  # our fetch_attepts helper would be renamed)
  #
  # TODO "attempts" does not mean "failure". But "attempt" that we store are
  # only failures, not successes. So we should rename to "failure".
  def attempts(%__MODULE__{} = wf, key) do
    case normalize_key(key, wf.default_ns) |> dbg() do
      {:ok, fk} -> fetch_attempts(wf, fk)
      {:error, reason} -> {:error, %GraphError{reason: reason}}
    end
  end

  defp fetch_attempts(wf, fk) do
    {ns, name, _} = fk

    case wf.store.attempts do
      %{^fk => found} -> {:ok, found}
      _ when is_map_key(wf.rules, {ns, name}) -> {:ok, %{}}
      _ -> {:error, %GraphError{reason: {:unknown_rule, fk}}}
    end
  end

  def dump(_wf) do
    raise "todo"
  end

  def load(_wf, _data) do
    raise "todo"
  end

  def clear_failure(_wf, _key_or_pred) do
    raise "todo"
  end

  defp normalize_identity!({ns, name} = identity, _wf)
       when is_name(ns) and is_name(name) do
    identity
  end

  defp normalize_identity!(name, %{default_ns: ns}) when is_name(name) do
    {ns, name}
  end

  defp normalize_identity!(other, _wf) do
    raise GraphError, reason: {:invalid_identity, other}
  end

  defp validate_rule!(rule, {ns, _} = identity) when is_map(rule) do
    case Ark.Opts.validate(rule, %{}, [required: [:alts]], &validate_rule_opt(&1, &2, ns)) do
      {:ok, _} -> rule
      {:error, e} -> raise rule_error(e, identity)
    end
  end

  defp validate_rule!(rule, identity) do
    e = %Ark.Opts.Error{kind: :invalid_value, path: [], value: rule, reason: "a map"}
    raise GraphError, rule: identity, reason: {:invalid_rule, e}
  end

  defp validate_rule_opt(:alts, [_ | _] = alts, ns) do
    with {:ok, _} <- Ark.Opts.validate(alts, %{}, &validate_alt(&1, &2, ns)) do
      {:ok, alts}
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

  defp validate_alt(name, alt, ns) when is_name(name) do
    Ark.Opts.all_of(alt, [&Ark.Opts.map/1, &validate_alt_map(&1, ns)])
  end

  defp validate_alt(_name, _alt, _ns) do
    :unknown
  end

  defp validate_alt_map(alt, ns) do
    Ark.Opts.validate(alt, %{}, [required: [:deps, :body]], fn
      :body, body ->
        validate_callback(body, 3)

      :deps, deps ->
        Ark.Opts.all_of(deps, [
          Ark.Opts.list_of(&validate_dep/1),
          &validate_exposed_keys(&1, ns)
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

  defp validate_dep(fun) when is_function(fun) do
    Ark.Opts.function(fun, 3)
  end

  defp validate_dep({_, _, args} = mfa) when is_list(args) do
    Ark.Opts.mfa(mfa)
  end

  defp validate_dep(aliases) when is_map(aliases) and not is_struct(aliases) do
    Enum.reduce_while(aliases, {:ok, aliases}, fn {_, dep}, ok ->
      case validate_static_key(dep) do
        {:ok, _} -> {:cont, ok}
        {:error, reason} -> {:halt, {:error, %GraphError{reason: reason}}}
      end
    end)
  end

  defp validate_dep(dep) do
    case validate_static_key(dep) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, %GraphError{reason: reason}}
    end
  end

  defp validate_static_key(name) when is_name(name) do
    {:ok, name}
  end

  defp validate_static_key({name, params} = key) when is_name(name) do
    case validate_params(params) do
      {:ok, _} -> {:ok, key}
      {:error, _} -> {:error, {:invalid_params, key}}
    end
  end

  defp validate_static_key({ns, name, params} = key)
       when is_name(ns) and is_name(name) do
    case validate_params(params) do
      {:ok, _} -> {:ok, key}
      {:error, _} -> {:error, {:invalid_params, key}}
    end
  end

  defp validate_static_key(other) do
    {:error, {:invalid_key, other}}
  end

  defp validate_params(params) do
    Ark.Opts.all_of(params, [&Ark.Opts.map/1, &validate_param_term/1])
  end

  defp validate_param_term(term)
       when is_pid(term) or is_port(term) or is_reference(term) or is_function(term) do
    {:error, "a term without pids, ports, references or functions"}
  end

  defp validate_param_term(map) when is_map(map) do
    with {:ok, _} <- validate_param_term(:maps.to_list(map)) do
      {:ok, map}
    end
  end

  defp validate_param_term(tuple) when is_tuple(tuple) do
    with {:ok, _} <- validate_param_term(Tuple.to_list(tuple)) do
      {:ok, tuple}
    end
  end

  defp validate_param_term([head | tail] = list) do
    with {:ok, _} <- validate_param_term(head),
         {:ok, _} <- validate_param_term(tail) do
      {:ok, list}
    end
  end

  defp validate_param_term(term) do
    {:ok, term}
  end

  defp validate_exposed_keys(deps, ns) do
    exposed =
      for dep(alias: alias_name, key: key, source: source) <- normalize_deps(deps, ns) do
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

  defp normalize_rule(rule, ns) do
    alts =
      Enum.map(rule.alts, fn {key, alt} ->
        {key, %{alt | deps: normalize_deps(alt.deps, ns)}}
      end)

    %{rule | alts: alts}
  end

  # maps should be wrapped in a list
  defp normalize_deps(deps, ns) when is_list(deps) do
    deps
    |> Enum.flat_map(&normalize_dep(&1, ns))
    |> Enum.uniq()
  end

  defp normalize_dep(aliases, ns) when is_map(aliases) do
    aliases
    |> :maps.iterator(:ordered)
    |> :maps.to_list()
    |> Enum.map(fn {alias_name, key} ->
      dep(alias: alias_name, key: full_key(key, ns), source: :alias)
    end)
  end

  defp normalize_dep(fun, _ns) when is_function(fun) do
    [dyn(callback: fun)]
  end

  defp normalize_dep({_, _, args} = mfa, _ns) when is_list(args) do
    [dyn(callback: mfa)]
  end

  defp normalize_dep(key, ns) do
    [dep(alias: key, key: full_key(key, ns), source: :key)]
  end

  defp normalize_key(key, ns) do
    {:ok, full_key(key, ns)}
  catch
    {:invalid_key, _} = reason -> {:error, reason}
    {:invalid_params, _} = reason -> {:error, reason}
  end

  defp full_key(name, ns) when is_name(name) do
    {ns, name, %{}}
  end

  defp full_key({name, params} = key, ns) when is_name(name) do
    {ns, name, valid_params!(params, key)}
  end

  defp full_key({ns, name, params} = key, _ns) when is_name(ns) and is_name(name) do
    {ns, name, valid_params!(params, key)}
  end

  defp full_key(other, _ns) do
    throw({:invalid_key, other})
  end

  defp valid_params!(params, key) do
    case validate_params(params) do
      {:ok, _} -> params
      {:error, _} -> throw({:invalid_params, key})
    end
  end

  defp run_loop([frame(key: key) = x], %{results: results}, _wf)
       when is_map_key(results, key) do
    raise "already ran"
  end

  defp run_loop(
         [frame(key: key, arms: [arm() = arm | arms]) = frame | frames],
         store,
         wf
       ) do
    IO.puts("== frame #{inspect(debug_frame(frame))}")

    arm(key: alt_key) = arm

    case pull_deps(arm, store, key, wf) do
      {:ready, arm(alt: :targets)} ->
        run_loop(frames, store, wf)

      {:needy, arm(deps: [dep(key: dep_key) | _]) = arm} ->
        frame = frame(frame, arms: [arm | arms])
        stack = [frame | frames]
        stack = push_frame(stack, dep_key, store, wf)
        run_loop(stack, store, wf)

      {:ready, arm} ->
        {_, _, params} = key

        IO.puts("== call #{inspect(key)} / inspect #{alt_key}")

        case call_arm(arm, params, wf) do
          {:ok, value} ->
            IO.puts("== call succeeded")

            store = put_result(store, key, {:ok, value})
            run_loop(frames, store, wf)

          {:error, reason} = err ->
            IO.puts("== call failed")

            store =
              put_attempt(store, key, alt_key, {:computation_error, :user_term, reason})

            frame = frame(frame, arms: arms)
            run_loop([frame | frames], store, wf)
        end

      {:error, :dep_failed, dep(key: dep_key) = dep} ->
        store = put_attempt(store, key, alt_key, {:dep_failed, dep_key})
        frame = frame(frame, arms: arms)
        run_loop([frame | frames], store, wf)
    end
  end

  # No more arms to this frame
  defp run_loop([frame(key: {ns, name, _} = key, arms: []) | frames], store, wf) do
    %{rules: %{{^ns, ^name} => rule}} = wf
    attempted = Map.get(store.attempts, key, %{})

    failed =
      for {alt_key, _} <- rule.alts, is_map_key(attempted, alt_key) do
        alt_key
      end

    store = put_result(store, key, {:failed, {:all_alternatives_failed, failed}})
    run_loop(frames, store, wf)
  end

  defp run_loop([], store, wf) do
    {:ok, [], store}
  end

  #

  defp push_frame(stack, fk, store, wf) do
    case List.keyfind(stack, fk, frame(:key)) do
      nil ->
        frame = new_frame(fk, store, wf)
        IO.puts("== push frame #{inspect(debug_frame(frame))}")
        [frame | stack]

      _ ->
        stack
    end
  end

  defp new_frame({ns, name, _} = fk, store, wf) do
    rule_key = {ns, name}
    attempted = Map.get(store.attempts, fk, %{})

    case wf do
      %{rules: %{^rule_key => rule}} ->
        frame(
          key: fk,
          arms:
            for {key, alt} <- rule.alts, not is_map_key(attempted, key) do
              %{deps: deps} = alt
              arm(key: key, deps: deps, acc: %{}, alt: alt)
            end
        )

      _ ->
        throw({:stop_run, %GraphError{reason: {:unknown_rule, fk}}, wf})
    end
  end

  #

  #

  #

  defp pull_deps(arm(deps: []) = arm, _store, key, wf) do
    {:ready, arm}
  end

  defp pull_deps(arm(deps: [_ | _] = deps, acc: acc) = arm, store, key, wf) do
    case do_pull_deps(deps, acc, store, key, wf) do
      {:ok, remaining_deps, acc} ->
        arm = arm(arm, deps: remaining_deps, acc: acc)

        case remaining_deps do
          [] -> {:ready, arm}
          _ -> {:needy, arm}
        end

      {:error, :dep_failed, dep} ->
        {:error, :dep_failed, dep}
    end
  end

  defp do_pull_deps([dep(alias: alias_name, key: fk) = dep | deps], acc, store, key, wf) do
    case store.results do
      %{^fk => {:ok, dep_val}} ->
        acc = Map.put(acc, alias_name, dep_val)
        do_pull_deps(deps, acc, store, key, wf)

      %{^fk => {:failed, _} = err} ->
        {:error, :dep_failed, dep}

      _ ->
        {:ok, [dep | deps], acc}
    end
  end

  @doc """
  TODO deps validation normalize_deps assumes its input has already passed
  validate_rule!, and what a dependency function returns hasn't. The skipped 06
  tests (06_dependency_functions_test.exs:450-562) show that the runtime check
  also differs from the static one in a few ways.

  What the runtime check has to cover:

  1. Return shape. A dependency function can return a single key, an alias map,
     or a list of keys. In a returned list, every element must be a key: [[:a]],
     [:a, [:b]] and [%{x: :a}] are all {:invalid_key, element}, and the error
     names the offending element. Static deps lists do allow maps and functions,
     so normalize_deps can't be reused without a shape check first.
  2. Each key. validate_static_key/1 already returns exactly {:invalid_key, v}
     or {:invalid_params, v}. nil, true and false fail is_address, so they come
     out as :invalid_key as the tests expect.
  3. {:ok, keys}. This needs a dedicated error whose message says the keys
     should be returned directly.
  4. Unknown rule. prerun_check! only covers static deps, so returned keys need
     an {:unknown_rule, fk} check at call time.
  5. Shadowing. A returned key conflicts with anything already exposed by the
     alternative: static deps on either side of the function, and keys returned
     by earlier dependency functions.

  All of these errors are wrapped as {:bad_return, :deps, fun, value, reason} in
  a GraphError that stops the run, with rule, key and alternative set.

  Suggested structure:

  - Have check_exposed_keys/2 return {:ok, seen} instead of :ok. Then seen
    doubles as a running record of what the alternative exposes so far.
  - Add an exposed field to arm, initialized in new_frame from the static deps
    of the alternative. They were validated at add_rule, so building it can't
    conflict. This covers "static dep to its right", because the whole static
    list is in there from the start.
  - In the dyn clause: validate the shape and keys, normalize, check the rules
    exist, then run check_exposed_keys(new_exposures, arm.exposed) and store the
    returned seen back in the arm. This covers "returned by an earlier
    dependency function", and it's where source gets used.

  The shape check can be one function that returns {:ok, [dep]} or {:error,
  reason}. It would be built from validate_static_key/1 and normalize_dep/2:

  - {:ok, _}: the "return the keys directly" error.
  - Map: validate each value as a static key, then turn the map into dep(...,
    source: :alias) entries.
  - List: each element must pass validate_static_key, which rejects maps and
    nested lists. Each one becomes a dep(..., source: :key).
  - Anything else: validate it as a single static key.
  """

  defp do_pull_deps([dyn(callback: fun) = dep | deps], acc, store, key, wf) do
    {ns, _, params} = key

    new_deps = call_dep(fun, params, acc, wf)
    new_deps = normalize_deps([new_deps], ns)

    do_pull_deps(new_deps ++ deps, acc, store, key, wf)
  end

  defp do_pull_deps([], acc, _store, _key, _wf) do
    {:ok, [], acc}
  end

  #

  defp call_arm(arm, params, wf) do
    arm(acc: acc, alt: %{body: body}) = arm
    %{ctx: ctx} = wf

    case call_impl(body, {params, acc, ctx}) do
      {:ok, v} -> {:ok, v}
      {:error, _} = err -> err
      other -> raise "todo bad arm return: #{inspect(other)}"
    end
  end

  defp call_dep(fun, params, acc, wf) do
    %{ctx: ctx} = wf

    case call_impl(fun, {params, acc, ctx}) do
      map when is_map(map) -> map
    end
  end

  defp call_impl(fun, {params, acc, ctx}) when is_function(fun, 3) do
    fun.(params, acc, ctx)
  end

  defp call_impl({m, f, a}, {params, acc, ctx}) do
    apply(m, f, [params, acc, ctx | a])
  end

  #

  defp put_result(store, key, result) do
    %{store | results: Map.put(store.results, key, result)}
  end

  defp put_attempt(store, key, alt_key, {:computation_error, kind, reason}) do
    error = %{
      at: DateTime.utc_now(),
      kind: kind,
      message: Ark.Error.to_string(reason),
      reason: reason
    }

    put_attempt(store, key, alt_key, {:computation_error, error})
  end

  defp put_attempt(store, key, alt_key, record) do
    attempts =
      Map.update(store.attempts, key, %{alt_key => record}, &Map.put(&1, alt_key, record))

    %{store | attempts: attempts}
  end

  #

  #

  #

  #

  defp prerun_check!(wf, targets) do
    Enum.each(targets, &prerun_check_target!(&1, wf))
    Enum.each(wf.rules, &prerun_check_rule_deps!(&1, wf))
    wf
  end

  defp prerun_check_target!(target, wf) do
    case normalize_key(target, wf.default_ns) do
      {:ok, {ns, name, _} = key} when not is_map_key(wf.rules, {ns, name}) ->
        throw({:stop_run, %GraphError{reason: {:unknown_rule, key}}, wf})

      {:ok, _} ->
        :ok

      {:error, reason} ->
        throw({:stop_run, %GraphError{reason: reason}, wf})
    end
  end

  defp prerun_check_rule_deps!({rule_key, rule}, wf) do
    Enum.each(rule.alts, fn {ak, %{deps: deps}} ->
      Enum.each(deps, &check_dep!(&1, rule_key, ak, wf))
    end)
  end

  defp check_dep!(dep(key: {ns, name, _} = key), rule_key, ak, wf) do
    if not Map.has_key?(wf.rules, {ns, name}) do
      e = %GraphError{rule: rule_key, alternative: ak, reason: {:unknown_rule, key}}
      throw({:stop_run, e, wf})
    end
  end

  defp check_dep!(dyn(), _rule_key, _ak, _wf) do
    :ok
  end

  #

  #

  #

  #

  #

  #

  #

  #

  #

  #

  def debug_stack(stack) when is_list(stack) do
    Enum.map(stack, &debug_frame/1)
  end

  def debug_stack(%__MODULE__{stack: stack}) do
    stack
  end

  defp debug_frame(frame() = rec) do
    rec
    |> frame()
    |> Map.new()
    |> Map.update!(:arms, &Enum.map(&1, fn arm -> debug_frame(arm) end))
  end

  defp debug_frame(arm() = rec) do
    rec |> arm() |> Map.new()
  end
end
