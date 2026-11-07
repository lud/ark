defmodule Ark.Workflow do
  alias Ark.Workflow.CodecError
  alias Ark.Workflow.ComputationError
  alias Ark.Workflow.GraphError
  require Record

  defstruct rules: %{},
            default_ns: :default,
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

    # The deps reached so far, as dep records by alias
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

  def new(opts) when is_list(opts) do
    opts = Ark.Opts.validate!(opts, %{call_wrapper: nil}, [], &validate_new_opt(&1, &2))

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

  defp validate_new_opt(_, _) do
    :unknown
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

  def add_ns(%__MODULE__{}, new_ns, _callback) when not is_name(new_ns) do
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
    case validate_static_keys(Map.values(aliases)) do
      {:ok, _} -> {:ok, aliases}
      {:error, reason} -> {:error, %GraphError{reason: reason}}
    end
  end

  defp validate_dep(dep) do
    case validate_static_key(dep) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, %GraphError{reason: reason}}
    end
  end

  defp validate_static_keys(keys) do
    Ark.Ok.map_ok(keys, &validate_static_key/1)
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

  defp rule_key({ns, name, params})
       when is_name(ns) and is_name(name) and is_map(params) do
    {ns, name}
  end

  defp rule_key({ns, name}) when is_name(ns) and is_name(name) do
    {ns, name}
  end

  defp rule_key({name, params}, ns) when is_name(name) and is_map(params) do
    {ns, name}
  end

  defp rule_key(name, ns) when is_name(name) do
    {ns, name}
  end

  defp rule_key(key, _ns) do
    rule_key(key)
  end

  defp rule_of(key, %__MODULE__{rules: rules, default_ns: ns}) do
    Map.fetch(rules, rule_key(key, ns))
  end

  defp rule_of(key, %{rules: rules}) do
    Map.fetch(rules, rule_key(key))
  end

  defp read_key!(wf, key) do
    case normalize_key(key, wf.default_ns) do
      {:ok, full_key} -> full_key
      {:error, reason} -> raise GraphError, reason: reason
    end
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

  # TODO normalize targets in run() or prerun_check!(), and remove default_ns
  # from state
  def run(%__MODULE__{} = wf, targets, opts \\ []) do
    %{store: store, rules: rules} = wf

    opts =
      Ark.Opts.validate!(
        opts,
        %{call_wrapper: wf.call_wrapper, context: %{}},
        [],
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

  # TODO fail on unknown options

  defp prerun_check!(wf, targets, state) do
    keys = Enum.map(targets, &prerun_check_target!(&1, wf, state))
    Enum.each(wf.rules, &prerun_check_rule_deps!(&1, state))
    keys
  end

  defp prerun_check_target!(target, wf, state) do
    case normalize_key(target, wf.default_ns) do
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

  defp run_loop(%{store: %{results: results}, stack: [frame(key: key)]})
       when is_map_key(results, key) do
    raise "already ran"
  end

  defp run_loop(state) do
    run_frame(state)
  end

  defp run_frame(
         %{stack: [frame(key: key, arms: [arm(key: alt_key) = arm | _]) | _]} = state
       ) do
    meta = %{key: key, alternative: alt_key}

    case pull_deps(arm, meta, state) do
      {:ready, arm(alt: :targets)} ->
        run_loop(pop_frame(state))

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
  defp run_frame(%{stack: [frame(key: key, arms: []) | _]} = state) do
    {:ok, rule} = rule_of(key, state)
    attempted = Map.get(state.store.attempts, key, %{})

    failed =
      for {alt_key, _} <- rule.alts, is_map_key(attempted, alt_key) do
        alt_key
      end

    state = put_result(state, key, {:failed, {:all_alternatives_failed, failed}})
    run_loop(pop_frame(state))
  end

  defp run_frame(%{stack: []} = state) do
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
              arm(key: key, deps: deps, acc: %{}, alt: alt)
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

  defp pull_deps(arm(deps: deps, acc: acc) = arm, meta, state) do
    case do_pull_deps(deps, acc, meta, state) do
      {:ok, remaining_deps, acc} ->
        arm = arm(arm, deps: remaining_deps, acc: acc)

        case remaining_deps do
          [] -> {:ready, arm}
          _ -> {:needy, arm}
        end

      err ->
        err
    end
  end

  defp do_pull_deps(
         [dep(alias: alias_name, key: full_key, source: source) = dep | deps],
         acc,
         meta,
         state
       ) do
    case acc do
      %{^alias_name => dep(key: ^full_key)} ->
        pull_dep(dep, deps, acc, meta, state)

      %{^alias_name => dep(key: seen_key, source: seen_source)} ->
        {:error, :graph,
         {:shadowing, {alias_name, seen_key, seen_source}, {alias_name, full_key, source}}}

      _ ->
        pull_dep(dep, deps, Map.put(acc, alias_name, dep), meta, state)
    end
  end

  defp do_pull_deps([dyn(callback: fun) | deps], acc, meta, state) do
    case call_dep(fun, dep_values(acc, state.store), meta, state) do
      {:ok, new_deps} -> do_pull_deps(new_deps ++ deps, acc, meta, state)
      err -> err
    end
  end

  defp do_pull_deps([], acc, _meta, _state) do
    {:ok, [], acc}
  end

  defp pull_dep(dep(key: full_key) = dep, deps, acc, meta, state) do
    case state.store.results do
      %{^full_key => {:ok, _}} -> do_pull_deps(deps, acc, meta, state)
      %{^full_key => {:failed, _}} -> {:failed, {:dep_failed, full_key}}
      _ -> {:ok, [dep | deps], acc}
    end
  end

  defp dep_values(acc, store) do
    Map.new(acc, fn {alias_name, dep(key: full_key)} ->
      %{^full_key => {:ok, value}} = store.results
      {alias_name, value}
    end)
  end

  defp call_arm(arm, meta, state) do
    arm(acc: acc, alt: %{body: body}) = arm
    %{ctx: ctx, store: store} = state
    {_, _, params} = meta.key
    call = build_call(body, params, dep_values(acc, store), ctx)

    case call_impl(:computation, meta, call, state) do
      {:ok, v} ->
        {:ok, v}

      {:error, :comp, {kind, e, stacktrace}} ->
        {:failed, computation_error(kind, e, stacktrace)}

      {:error, reason} ->
        {:failed, computation_error(:user_term, reason, nil)}

      other ->
        {:failed, computation_error(:bad_return, other, nil)}
    end
  end

  defp call_dep(fun, acc, meta, state) do
    %{ctx: ctx} = state
    {ns, _, params} = meta.key
    call = build_call(fun, params, acc, ctx)

    case call_impl(:deps, meta, call, state) do
      {:error, :comp, {kind, e, stacktrace}} ->
        {:failed, computation_error(kind, e, stacktrace)}

      value ->
        with {:ok, _} <- validate_returned_deps(value),
             new_deps = normalize_deps(List.wrap(value), ns),
             {:ok, new_deps} <- Ark.Ok.map_ok(new_deps, &check_known_rule(&1, state)) do
          {:ok, new_deps}
        else
          {:error, reason} ->
            {:error, :graph, {:bad_return, :deps, fun, value, reason}}
        end
    end
  end

  # Special handling of an :ok tuple. Dynamic deps functions must return bare
  # values (maps, list) so an OK tuple is invalid.
  #
  # TODO special case in exception message generation to explain the return
  # value of dependency callbacks
  defp validate_returned_deps({:ok, _} = value) do
    {:error, {:invalid_key, value}}
  end

  # TODO should {:a, _} shadow explicit {:default, :a, _} ?
  defp validate_returned_deps(aliases) when is_map(aliases) and not is_struct(aliases) do
    validate_static_keys(Map.values(aliases))
  end

  defp validate_returned_deps(keys) when is_list(keys) do
    validate_static_keys(keys)
  end

  defp validate_returned_deps(key) do
    validate_static_keys([key])
  end

  defp call_impl(kind, meta, call, state) do
    %{call_wrapper: call_wrapper} = state

    case call_wrapped(call_wrapper, kind, meta, call) do
      {:error, :comp, _} -> exit(:invalid_return)
      other -> other
    end
  rescue
    e -> {:error, :comp, {:error, e, __STACKTRACE__}}
  catch
    kind, e -> {:error, :comp, {kind, e, __STACKTRACE__}}
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

  def invoke({m, f, args}) do
    apply(m, f, args)
  end

  def invoke({fun, args}) when is_function(fun) do
    apply(fun, args)
  end

  # defp call_wrapped({m, f, a}, kind, meta, call) do
  #   apply(m, f, [kind, meta, call | a])
  # end

  # defp call_wrapped(fun, kind, meta, call) do
  #   fun.(kind, meta, call)
  # end

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

  def fetch(%__MODULE__{} = wf, key) do
    full_key = read_key!(wf, key)

    case wf.store.results do
      %{^full_key => result} -> result
      _ -> :error
    end
  end

  # TODO we need to normalize the API function names. "attempts" should return
  # raw value. Since we return a result tuple, it should be fetch_attempts (and
  # our fetch_attepts helper would be renamed)
  #
  # TODO "attempts" does not mean "failure". But "attempt" that we store are
  # only failures, not successes. So we should rename to something like
  # "failures", but we also have a "failures" function that returns a tree
  # (could be renamed "blame")
  def attempts(%__MODULE__{} = wf, key) do
    {:ok, Map.get(wf.store.attempts, read_key!(wf, key), %{})}
  end

  def failures(%__MODULE__{} = wf, key) do
    fetch_failures(wf, [read_key!(wf, key)], %{})
  end

  defp fetch_failures(wf, [full_key | keys], acc) when is_map_key(acc, full_key) do
    # this should not happen since we check when pulling the deps
    raise "already seen"
    fetch_failures(wf, keys, acc)
  end

  defp fetch_failures(wf, [full_key | keys], acc) do
    case wf.store do
      %{results: %{^full_key => {:failed, _}}} ->
        attempts = Map.get(wf.store.attempts, full_key, %{})

        deps =
          Enum.flat_map(attempts, fn
            {_alt, {:dep_failed, dep_key}} when not is_map_key(acc, dep_key) -> [dep_key]
            _ -> []
          end)

        acc = Map.put(acc, full_key, attempts)
        fetch_failures(wf, deps ++ keys, acc)

      _other ->
        {:error, :not_failed}
    end
  end

  defp fetch_failures(_wf, [], acc) do
    {:ok, acc}
  end

  def clear_failure(%__MODULE__{} = wf, pred) when is_function(pred, 1) do
    roots =
      for {k, {:failed, _}} <- wf.store.results, pred.(k) do
        k
      end

    clear_roots(wf, roots)
  end

  def clear_failure(%__MODULE__{} = wf, key) do
    full_key = read_key!(wf, key)

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
    %{results: results, attempts: attempts} = wf.store

    # Index all dependency failures from the state, regardless of what roots are
    # asked. Key is a dependency key, value is the [{dependent_key,
    # alternative}] list from transitive failures (failed because of that
    # dependedency).
    index =
      for {dependent, alts} <- attempts, {alt, {:dep_failed, dep}} <- alts, reduce: %{} do
        acc -> Map.update(acc, dep, [{dependent, alt}], &[{dependent, alt} | &1])
      end

    results = Map.drop(results, roots)
    # Drop all failures of all alternatives for the roots that were asked
    attempts = Map.drop(attempts, roots)

    {results, attempts} =
      clear_dependents(roots, index, results, attempts)

    {:ok, %{wf | store: %{wf.store | results: results, attempts: attempts}}}
  end

  defp clear_dependents([cleared | queue], index, results, attempts) do
    {queue, results, attempts} =
      index
      |> Map.get(cleared, [])
      |> Enum.reduce({queue, results, attempts}, fn
        {dependent, alt}, {queue, results, attempts} ->
          # Delete the alt of "dependent" that failed because of our cleared failure
          attempts = maybe_delete_alt(attempts, dependent, alt)

          # if dependent was failed we remove its failure
          case results do
            %{^dependent => {:failed, _}} ->
              {[dependent | queue], Map.delete(results, dependent), attempts}

            _ ->
              {queue, results, attempts}
          end
      end)

    clear_dependents(queue, index, results, attempts)
  end

  defp clear_dependents([], _index, results, attempts) do
    {results, attempts}
  end

  # Relaxed: the alternative may already be gone when the dependent is itself a
  # root, as its attempts were dropped after the index was built. Drops the
  # dependent's entry when its last alternative is deleted.
  defp maybe_delete_alt(attempts, dependent, alt) do
    case attempts do
      %{^dependent => alts} when is_map_key(alts, alt) ->
        if map_size(alts) == 1 do
          Map.delete(attempts, dependent)
        else
          Map.put(attempts, dependent, Map.delete(alts, alt))
        end

      _ ->
        attempts
    end
  end

  def dump(%__MODULE__{} = wf) do
    dump_store(wf.store, wf)
  catch
    {:dump_error, %CodecError{} = e} -> {:error, e}
  end

  defp dump_store(store, wf) do
    %{results: results, attempts: attempts} = store

    data = %{
      "results" => dump_results(results, wf),
      "attempts" => dump_attempts(attempts)
    }

    {:ok, data}
  end

  defp dump_results(results, wf) do
    Enum.map(results, &dump_result(&1, wf))
  end

  defp dump_result({key, result}, wf) do
    case result do
      {:ok, v} ->
        {:ok, rule} = rule_of(key, wf)
        %{"key" => dump_key(key), "ok" => 1, "v" => dump_success(v, key, rule)}

      {:failed, reason} ->
        %{"key" => dump_key(key), "ok" => 0, "v" => dump_failure(reason)}
    end
  catch
    {:bad_dump_term, _} = e ->
      throw({:dump_error, %CodecError{key: key, reason: e, direction: :dump}})
  end

  defp dump_success(value, key, rule) do
    case rule do
      %{dump: normalizer} ->
        case call_codec(normalizer, value) do
          {:ok, normal} ->
            dump_value(normal)

          {:error, e} ->
            throw({:dump_error, %CodecError{key: key, reason: e, direction: :dump}})
        end

      _no_dump ->
        dump_value(value)
    end
  end

  defp dump_attempts(attempts) do
    Enum.map(attempts, fn {key, by_alt} ->
      alts =
        Map.new(by_alt, fn {alt_key, failure} ->
          {dump_name(alt_key), dump_failure(failure)}
        end)

      %{"key" => dump_key(key), "alts" => alts}
    end)
  end

  defp dump_failure({:computation_error, cleaned_error}) do
    %{message: msg, at: at, stacktrace: stacktrace, kind: kind} = cleaned_error

    true = is_nil(stacktrace) or is_binary(stacktrace)

    %{
      "computation_error" => %{
        "message" => msg,
        "at" => DateTime.to_iso8601(at),
        "stacktrace" => stacktrace,
        "kind" => Atom.to_string(kind)
      }
    }
  end

  defp dump_failure({:dep_failed, dep_key}) do
    %{"dep_failed" => dump_key(dep_key)}
  end

  defp dump_failure({:all_alternatives_failed, alt_keys}) do
    %{"all_alternatives_failed" => Enum.map(alt_keys, &dump_name/1)}
  end

  defp dump_failure(other) do
    raise ArgumentError, "unknown failure record: #{inspect(other)}"
  end

  defp dump_key({ns, name, params}) do
    %{"ns" => dump_name(ns), "n" => dump_name(name), "ps" => dump_params(params)}
  end

  defp dump_name(name) when is_atom(name) do
    Atom.to_string(name)
  end

  defp dump_name(name) when is_binary(name) do
    name
  end

  defp dump_params(params) do
    dump_value(params)
  end

  defp dump_value(value) do
    case dump_strategy(value) do
      :json -> %{"json" => 1, "v" => value}
      :etf64 -> %{"json" => 0, "v" => etf_64(value)}
    end
  end

  defp dump_strategy(data) do
    case _dump_strategy(data, _use_json? = true) do
      true -> :json
      false -> :etf64
    end
  end

  # Walks over the whole map to verify if all subterms term json encodable
  # and/or can be persisted. Returns false when a term cannot be persisted as
  # json (like a tuple) but is still valid for storage. Throws when a term can
  # be stale on storage (pid, reference, port, function).
  #
  # Note: it is very important to not shortcut deep inspection by returning
  # `json?` if already false.
  defp _dump_strategy(d, json?)
       when is_number(d)
       when is_nil(d)
       when is_boolean(d) do
    json?
  end

  defp _dump_strategy(d, json?) when is_binary(d) do
    String.valid?(d) and json?
  end

  defp _dump_strategy(d, _json?) when is_struct(d) do
    _ = dump_strategy(Map.from_struct(d))
    false
  end

  defp _dump_strategy(d, json?) when is_map(d) do
    Enum.reduce(d, json?, fn {k, v}, json? ->
      _dump_strategy(v, _dump_strategy(k, json?) and is_binary(k) and String.valid?(k))
    end)
  end

  defp _dump_strategy([h | t] = _improper, json?) when not is_list(t) do
    _ = _dump_strategy(h, _dump_strategy(t, json?))
    false
  end

  defp _dump_strategy([h | t], json?) do
    _dump_strategy(h, _dump_strategy(t, json?))
  end

  defp _dump_strategy([], json?) do
    json?
  end

  defp _dump_strategy(d, _)
       when is_pid(d)
       when is_port(d)
       when is_reference(d)
       when is_function(d) do
    throw({:bad_dump_term, d})
  end

  defp _dump_strategy(d, _json?) when is_tuple(d) do
    _maybe_throws = dump_strategy(Tuple.to_list(d))

    false
  end

  defp _dump_strategy(_other, _) do
    false
  end

  defp etf_64(data) do
    data
    # TODO best compression options?
    |> :erlang.term_to_binary([:deterministic])
    |> Base.encode64()
  end

  def load(%__MODULE__{} = wf, data) do
    store = load_store(data, wf)
    {:ok, %{wf | store: store}}
  catch
    {:load_error, %CodecError{} = e} -> {:error, e}
  end

  defp load_store(raw, wf) do
    raw_results = Map.fetch!(raw, "results")
    true = is_list(raw_results)
    keyed_results = Enum.map(raw_results, &{load_key(Map.fetch!(&1, "key")), &1})

    raw_attempts = Map.fetch!(raw, "attempts")
    attempts = Map.new(raw_attempts, &load_attempt/1)

    check_known_rules!(Enum.map(keyed_results, &elem(&1, 0)) ++ Map.keys(attempts), wf)

    results =
      Map.new(keyed_results, fn {key, raw_result} ->
        {key, load_result(raw_result, key, wf)}
      end)

    %{results: results, attempts: attempts}
  rescue
    e ->
      throw({:load_error, %CodecError{reason: e, direction: :load}})
  end

  defp check_known_rules!(keys, wf) do
    unknown =
      for {ns, name, _} <- keys, not is_map_key(wf.rules, {ns, name}), uniq: true do
        {ns, name}
      end

    if unknown != [] do
      reason = {:unknown_rules, unknown}
      throw({:load_error, %CodecError{reason: reason, direction: :load}})
    end
  end

  defp load_result(raw_result, key, wf) do
    case raw_result do
      %{"ok" => 1, "v" => raw_value} ->
        {:ok, rule} = rule_of(key, wf)
        {:ok, load_success(raw_value, key, rule)}

      %{"ok" => 0, "v" => raw_value} ->
        {:failed, load_failure(raw_value)}
    end
  end

  defp load_success(raw_value, key, rule) do
    case rule do
      %{load: denormalizer} ->
        normal = load_value(raw_value)

        case call_codec(denormalizer, normal) do
          {:ok, value} ->
            value

          {:error, e} ->
            throw({:load_error, %CodecError{key: key, reason: e, direction: :load}})
        end

      _no_load ->
        load_value(raw_value)
    end
  end

  defp call_codec(codec, value) do
    {:ok, do_call_codec(codec, value)}
  rescue
    e -> {:error, e}
  end

  defp do_call_codec(fun, value) when is_function(fun) do
    fun.(value)
  end

  defp do_call_codec({m, f, args}, value) do
    apply(m, f, [value | args])
  end

  defp load_attempt(raw_attempt) do
    %{"key" => raw_key, "alts" => raw_alts} = raw_attempt
    key = load_key(raw_key)

    by_alt =
      Map.new(raw_alts, fn {raw_alt_key, raw_failure} ->
        {maybe_load_atom(raw_alt_key), load_failure(raw_failure)}
      end)

    {key, by_alt}
  end

  defp load_failure(%{"computation_error" => raw_error} = raw) do
    with %{
           "message" => msg,
           "at" => raw_at,
           "stacktrace" => stacktrace,
           "kind" => raw_kind
         }
         when is_binary(msg) and (is_nil(stacktrace) or is_binary(stacktrace)) <-
           raw_error,
         {:ok, at, _} <- DateTime.from_iso8601(raw_at),
         {:ok, kind} <- load_error_kind(raw_kind) do
      {:computation_error,
       %{at: at, kind: kind, message: msg, stacktrace: stacktrace, reason: nil}}
    else
      _ -> malformed_failure(raw)
    end
  end

  defp load_failure(%{"dep_failed" => raw_key}) do
    {:dep_failed, load_key(raw_key)}
  end

  defp load_failure(%{"all_alternatives_failed" => raw_alt_keys} = raw) do
    if is_list(raw_alt_keys) and Enum.all?(raw_alt_keys, &is_binary/1) do
      {:all_alternatives_failed, Enum.map(raw_alt_keys, &maybe_load_atom/1)}
    else
      malformed_failure(raw)
    end
  end

  defp load_failure(raw) do
    malformed_failure(raw)
  end

  @spec malformed_failure(term) :: no_return()
  defp malformed_failure(raw) do
    throw({:load_error, %CodecError{reason: {:malformed_failure, raw}, direction: :load}})
  end

  defp load_error_kind(raw_kind) do
    case raw_kind do
      "error" -> {:ok, :error}
      "throw" -> {:ok, :throw}
      "exit" -> {:ok, :exit}
      "user_term" -> {:ok, :user_term}
      "bad_return" -> {:ok, :bad_return}
      _ -> :error
    end
  end

  defp load_key(%{"ns" => raw_ns, "n" => raw_name, "ps" => raw_params}) do
    {maybe_load_atom(raw_ns), maybe_load_atom(raw_name), load_params(raw_params)}
  end

  defp maybe_load_atom(value) do
    String.to_existing_atom(value)
  catch
    :error, :badarg -> value
  end

  defp load_params(params) do
    load_value(params)
  end

  defp load_value(%{"json" => 1, "v" => data}) do
    data
  end

  defp load_value(%{"json" => 0, "v" => b64}) do
    b64
    |> Base.decode64!()
    |> :erlang.binary_to_term([:safe])
  end

  def debug_stack(stack) when is_list(stack) do
    Enum.map(stack, &debug_frame/1)
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
