defmodule Ark.Workflow do
  alias Ark.Workflow.ComputationError
  alias Ark.Workflow.GraphError
  alias Ark.Workflow.Middleware
  alias Ark.Workflow.Persistence

  defstruct ns: :default,
            rules: %{},
            values: %{},
            failed: %{},
            attempts: %{},
            orphans: %{},
            dump_check: false

  @type t :: %__MODULE__{}
  @type key :: {atom, atom, map}

  @rule_keys [:alts, :dump, :load]
  @alt_keys [:deps, :body]

  def new(opts \\ []) do
    opts =
      Ark.Opts.validate!(opts, %{dump_check: false}, [subject: "Ark.Workflow.new/1"], fn
        :dump_check, value -> Ark.Opts.boolean(value)
        _, _ -> :unknown
      end)

    %__MODULE__{dump_check: opts.dump_check}
  end

  def clear_failure(%__MODULE__{} = wf, predicate) when is_function(predicate, 1) do
    wf.failed |> Map.keys() |> Enum.filter(predicate) |> clear(wf)
  end

  def clear_failure(%__MODULE__{} = wf, key) do
    with {:ok, key} <- check_key(wf, key) do
      if is_map_key(wf.failed, key) do
        clear([key], wf)
      else
        {:error, :not_failed}
      end
    end
  end

  defp clear([], _wf) do
    {:error, :not_failed}
  end

  defp clear(keys, wf) do
    {:ok, Ark.Workflow.ClearFailure.clear(wf, keys)}
  end

  def dump(%__MODULE__{} = wf) do
    Persistence.dump(wf)
  end

  def load(%__MODULE__{} = wf, data) do
    Persistence.load(wf, data)
  end

  # -- Building the graph ----------------------------------------------------

  def add_rule(%__MODULE__{} = wf, identity, rule) do
    {ns, name} = parse_identity(identity, wf.ns)

    if is_map_key(wf.rules, {ns, name}) do
      graph_error!({:duplicate_rule, {ns, name}}, rule: {ns, name})
    end

    %{wf | rules: Map.put(wf.rules, {ns, name}, parse_rule(rule, ns, {ns, name}))}
  end

  def add_ns(%__MODULE__{} = wf, ns, callback) when is_function(callback, 1) do
    if !valid_name?(ns) do
      graph_error!({:invalid_namespace, ns}, [])
    end

    case callback.(%{wf | ns: ns}) do
      %__MODULE__{} = inner ->
        %{inner | ns: wf.ns}

      other ->
        graph_error!({:bad_return, :add_ns, callback, other, :not_a_graph}, [])
    end
  end

  defp parse_identity(identity, current_ns) do
    {ns, name} =
      case identity do
        {ns, name} -> {ns, name}
        name when is_atom(name) -> {current_ns, name}
        _ -> {nil, nil}
      end

    if valid_name?(ns) and valid_name?(name) do
      {ns, name}
    else
      graph_error!({:invalid_identity, identity}, [])
    end
  end

  defp valid_name?(term) do
    is_atom(term) and term not in [nil, true, false]
  end

  defp parse_rule(rule, ns, identity) when is_map(rule) do
    check_keys!(rule, @rule_keys, [], identity)

    alts =
      case rule do
        %{alts: alts} -> parse_alts(alts, ns, identity)
        _ -> invalid_rule!(identity, :missing_option, [:alts])
      end

    %{
      alts: alts,
      dump: parse_codec(rule, :dump, identity),
      load: parse_codec(rule, :load, identity)
    }
  end

  defp parse_rule(rule, _ns, identity) do
    invalid_rule!(identity, :invalid_value, [], rule, "a map")
  end

  defp check_keys!(map, allowed, path, identity) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      [key | _] -> invalid_rule!(identity, :unknown_option, path ++ [key])
    end
  end

  @spec invalid_rule!(term, atom, list, term, term) :: no_return
  defp invalid_rule!(identity, kind, path, value \\ nil, reason \\ nil) do
    error = %Ark.Opts.Error{kind: kind, path: path, value: value, reason: reason}

    alternative =
      case path do
        [:alts, name | _] -> name
        _ -> nil
      end

    graph_error!({:invalid_rule, error}, rule: identity, alternative: alternative)
  end

  defp parse_codec(rule, field, identity) do
    case rule do
      %{^field => fun} ->
        if callable?(fun, 1) do
          fun
        else
          invalid_rule!(
            identity,
            :invalid_value,
            [field],
            fun,
            "a function of arity 1 or a {module, function, args} tuple"
          )
        end

      _ ->
        nil
    end
  end

  defp callable?(fun, arity) when is_function(fun) do
    is_function(fun, arity)
  end

  defp callable?({m, f, args}, _) when is_atom(m) and is_atom(f) and is_list(args) do
    true
  end

  defp callable?(_, _) do
    false
  end

  defp parse_alts([_ | _] = alts, ns, identity) do
    parsed =
      Enum.map(alts, fn
        {name, alt} ->
          if !valid_name?(name) do
            invalid_rule!(
              identity,
              :invalid_value,
              [:alts],
              name,
              "alternative names as atoms other than nil, true and false"
            )
          end

          if !is_map(alt) do
            invalid_rule!(identity, :invalid_value, [:alts, name], alt, "a map")
          end

          {name, parse_alt(name, alt, ns, identity)}

        other ->
          invalid_rule!(identity, :invalid_value, [:alts], other, "a keyword list")
      end)

    names = Enum.map(parsed, &elem(&1, 0))

    case names -- Enum.uniq(names) do
      [] -> parsed
      [name | _] -> invalid_rule!(identity, :duplicate_option, [:alts, name])
    end
  end

  defp parse_alts(other, _ns, identity) do
    invalid_rule!(identity, :invalid_value, [:alts], other, "a non-empty keyword list")
  end

  defp parse_alt(name, alt, ns, identity) do
    check_keys!(alt, @alt_keys, [:alts, name], identity)

    for field <- @alt_keys, not is_map_key(alt, field) do
      invalid_rule!(identity, :missing_option, [:alts, name, field])
    end

    %{deps: deps, body: body} = alt

    if not is_list(deps) do
      invalid_rule!(identity, :invalid_value, [:alts, name, :deps], deps, "a list")
    end

    if !callable?(body, 3) do
      invalid_rule!(
        identity,
        :invalid_value,
        [:alts, name, :body],
        body,
        "a function of arity 3 or a {module, function, args} tuple"
      )
    end

    entries =
      deps
      |> Enum.with_index()
      |> Enum.map(fn {dep, index} -> parse_dep(dep, ns, identity, name, index) end)

    exposed = check_shadowing!(entries, identity, name)
    %{deps: entries, body: body, exposed: exposed}
  end

  defp parse_dep(fun, _ns, identity, alt, index) when is_function(fun) do
    if is_function(fun, 3) do
      {:fun, fun}
    else
      invalid_rule!(
        identity,
        :invalid_value,
        [:alts, alt, :deps, index],
        fun,
        "a function of arity 3"
      )
    end
  end

  defp parse_dep({m, f, args} = mfa, _ns, _identity, _alt, _index)
       when is_atom(m) and is_atom(f) and is_list(args) do
    {:fun, mfa}
  end

  defp parse_dep(map, ns, identity, alt, _index) when is_map(map) do
    {:alias,
     Enum.map(ordered_pairs(map), fn {a, k} ->
       {a, parse_dep_key(k, ns, identity, alt)}
     end)}
  end

  defp parse_dep(term, ns, identity, alt, _index) do
    {:key, term, parse_dep_key(term, ns, identity, alt)}
  end

  defp parse_dep_key(term, ns, identity, alt) do
    case parse_key(term, ns) do
      {:ok, key} -> key
      {:error, reason} -> graph_error!(reason, rule: identity, alternative: alt)
    end
  end

  defp check_shadowing!(entries, identity, alt) do
    exposures =
      Enum.flat_map(entries, fn
        {:fun, _} -> []
        {:key, term, key} -> [{term, key, :key}]
        {:alias, pairs} -> Enum.map(pairs, fn {a, key} -> {a, key, :alias} end)
      end)

    Enum.reduce(exposures, %{}, fn exposure, acc ->
      case expose(acc, exposure) do
        {:ok, acc} -> acc
        {:error, reason} -> graph_error!(reason, rule: identity, alternative: alt)
      end
    end)
  end

  defp expose(acc, {exposed, key, source} = exposure) do
    case acc do
      %{^exposed => {^key, _}} ->
        {:ok, acc}

      %{^exposed => {other, other_source}} ->
        {:error, {:shadowing, {exposed, other, other_source}, exposure}}

      _ ->
        {:ok, Map.put(acc, exposed, {key, source})}
    end
  end

  defp ordered_pairs(map) do
    map |> :maps.iterator(:ordered) |> collect_pairs([])
  end

  defp collect_pairs(iterator, acc) do
    case :maps.next(iterator) do
      {k, v, next} -> collect_pairs(next, [{k, v} | acc])
      :none -> :lists.reverse(acc)
    end
  end

  # -- Keys ------------------------------------------------------------------

  defp parse_key(name, ns) when is_atom(name) do
    if valid_name?(name) do
      {:ok, {ns, name, %{}}}
    else
      {:error, {:invalid_key, name}}
    end
  end

  defp parse_key({name, params} = given, ns) do
    cond do
      !valid_name?(name) -> {:error, {:invalid_key, given}}
      !valid_params?(params) -> {:error, {:invalid_params, given}}
      true -> {:ok, {ns, name, params}}
    end
  end

  defp parse_key({kns, name, params} = given, _ns) do
    cond do
      !(valid_name?(kns) and valid_name?(name)) -> {:error, {:invalid_key, given}}
      !valid_params?(params) -> {:error, {:invalid_params, given}}
      true -> {:ok, {kns, name, params}}
    end
  end

  defp parse_key(given, _ns) do
    {:error, {:invalid_key, given}}
  end

  defp valid_params?(params) when is_map(params) do
    valid_term?(params)
  end

  defp valid_params?(_) do
    false
  end

  @doc false
  def valid_term?(term) when is_pid(term) or is_port(term) or is_reference(term) do
    false
  end

  def valid_term?(term) when is_function(term) do
    false
  end

  def valid_term?(term) when is_map(term) do
    term |> :maps.to_list() |> valid_term?()
  end

  def valid_term?(term) when is_tuple(term) do
    term |> Tuple.to_list() |> valid_term?()
  end

  def valid_term?([h | t]) do
    valid_term?(h) and valid_term?(t)
  end

  def valid_term?(_) do
    true
  end

  # -- Reading ---------------------------------------------------------------

  def fetch(%__MODULE__{} = wf, key) do
    with {:ok, key} <- check_key(wf, key) do
      case wf do
        %{values: %{^key => value}} -> {:ok, value}
        %{failed: %{^key => record}} -> {:failed, record}
        _ -> :error
      end
    end
  end

  def attempts(%__MODULE__{} = wf, key) do
    with {:ok, key} <- check_key(wf, key) do
      {:ok, Map.get(wf.attempts, key, %{})}
    end
  end

  def failures(%__MODULE__{} = wf, key) do
    with {:ok, key} <- check_key(wf, key) do
      if is_map_key(wf.failed, key) do
        {:ok, collect_failures([key], wf, %{})}
      else
        {:error, :not_failed}
      end
    end
  end

  defp collect_failures([], _wf, acc) do
    acc
  end

  defp collect_failures([key | keys], wf, acc) when is_map_key(acc, key) do
    collect_failures(keys, wf, acc)
  end

  defp collect_failures([key | keys], wf, acc) do
    case failed_attempts(wf, key) do
      {:ok, attempts} ->
        deps =
          for {_, {:dep_failed, dep}} <- attempts do
            dep
          end

        collect_failures(deps ++ keys, wf, Map.put(acc, key, attempts))

      :error ->
        collect_failures(keys, wf, acc)
    end
  end

  defp failed_attempts(wf, key) do
    if is_map_key(wf.failed, key) do
      {:ok, Map.get(wf.attempts, key, %{})}
    else
      Persistence.orphan_failed_attempts(wf, key)
    end
  end

  defp check_key(wf, key) do
    case check_target(wf, key) do
      {:ok, key} -> {:ok, key}
      {:error, e} -> {:error, e}
    end
  end

  defp check_target(wf, key) do
    case parse_key(key, :default) do
      {:ok, {ns, name, _} = full} ->
        if is_map_key(wf.rules, {ns, name}) do
          {:ok, full}
        else
          {:error, %GraphError{reason: {:unknown_rule, full}}}
        end

      {:error, reason} ->
        {:error, %GraphError{reason: reason}}
    end
  end

  # -- Running ---------------------------------------------------------------

  def run(%__MODULE__{} = wf, targets, opts \\ []) when is_list(targets) do
    opts =
      Ark.Opts.validate!(
        opts,
        %{context: %{}, middlewares: []},
        [subject: "Ark.Workflow.run/3"],
        &run_opt/2
      )

    with :ok <- check_graph(wf),
         {:ok, targets} <- check_targets(wf, targets) do
      st = %{
        rules: wf.rules,
        context: opts.context,
        middlewares: opts.middlewares,
        values: wf.values,
        failed: wf.failed,
        attempts: wf.attempts,
        stack: [],
        in_progress: %{}
      }

      case run_targets(targets, st) do
        {:ok, st} -> {:ok, save(wf, st)}
        {:failed, target, st} -> {:error, ComputationError.new(target), save(wf, st)}
      end
    else
      {:error, e} -> {:error, e, wf}
    end
  catch
    {:graph_error, e, st} -> {:error, e, save(wf, st)}
  end

  defp run_opt(:context, value) do
    {:ok, value}
  end

  defp run_opt(:middlewares, value) do
    Ark.Opts.list_of(value, &{:ok, &1})
  end

  defp run_opt(_, _) do
    :unknown
  end

  defp save(wf, st) do
    %{wf | values: st.values, failed: st.failed, attempts: st.attempts}
  end

  defp check_graph(wf) do
    Enum.find_value(wf.rules, :ok, fn {identity, rule} ->
      Enum.find_value(rule.alts, fn {alt, %{deps: deps}} ->
        deps |> static_keys() |> Enum.find_value(&missing_rule(wf, &1, identity, alt))
      end)
    end)
  end

  defp static_keys(deps) do
    Enum.flat_map(deps, fn
      {:key, _, key} -> [key]
      {:alias, pairs} -> Enum.map(pairs, &elem(&1, 1))
      {:fun, _} -> []
    end)
  end

  defp missing_rule(wf, {ns, name, _} = key, identity, alt) do
    if !is_map_key(wf.rules, {ns, name}) do
      {:error,
       %GraphError{rule: identity, alternative: alt, reason: {:unknown_rule, key}}}
    end
  end

  defp check_targets(wf, targets) do
    targets
    |> Enum.reduce_while([], fn target, acc ->
      case check_target(wf, target) do
        {:ok, key} -> {:cont, [key | acc]}
        {:error, e} -> {:halt, {:error, e}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      keys -> {:ok, :lists.reverse(keys)}
    end
  end

  defp run_targets([], st) do
    {:ok, st}
  end

  defp run_targets([target | rest] = targets, st) do
    cond do
      is_map_key(st.values, target) -> run_targets(rest, st)
      is_map_key(st.failed, target) -> {:failed, target, st}
      true -> run_targets(targets, loop(push_frame(st, target)))
    end
  end

  defp push_frame(st, {ns, name, _} = key) do
    %{alts: all} = Map.fetch!(st.rules, {ns, name})
    attempted = Map.get(st.attempts, key, %{})
    alts = Enum.reject(all, fn {alt, _} -> is_map_key(attempted, alt) end)
    frame = %{key: key, ns: ns, all: all, alts: alts, cur: nil}
    %{st | stack: [frame | st.stack], in_progress: Map.put(st.in_progress, key, true)}
  end

  defp loop(%{stack: []} = st) do
    st
  end

  defp loop(%{stack: [frame | rest]} = st) do
    advance(frame, %{st | stack: rest})
  end

  defp advance(%{cur: nil, alts: []} = frame, st) do
    attempted = Map.get(st.attempts, frame.key, %{})

    names =
      for {alt, _} <- frame.all, is_map_key(attempted, alt) do
        alt
      end

    record = {:all_alternatives_failed, names}

    loop(%{
      st
      | failed: Map.put(st.failed, frame.key, record),
        in_progress: Map.delete(st.in_progress, frame.key)
    })
  end

  defp advance(%{cur: nil, alts: [{name, alt} | more]} = frame, st) do
    cur = %{
      name: name,
      body: alt.body,
      entries: alt.deps,
      pending: [],
      deps: %{},
      exposed: alt.exposed
    }

    advance(%{frame | alts: more, cur: cur}, st)
  end

  defp advance(%{cur: %{pending: [{exposed, key} | more]} = cur} = frame, st) do
    %{values: values, failed: failed} = st

    cond do
      is_map_key(values, key) ->
        cur = %{
          cur
          | pending: more,
            deps: Map.put(cur.deps, exposed, Map.fetch!(values, key))
        }

        advance(%{frame | cur: cur}, st)

      is_map_key(failed, key) ->
        alt_failed(frame, {:dep_failed, key}, st)

      is_map_key(st.in_progress, key) ->
        throw({:graph_error, cycle_error(key, frame, st), st})

      not is_map_key(st.rules, {elem(key, 0), elem(key, 1)}) ->
        record =
          computation_record(
            :error,
            "no rule registered for #{format_key(key)}",
            %GraphError{reason: {:unknown_rule, key}},
            nil
          )

        alt_failed(frame, record, st)

      true ->
        loop(push_frame(%{st | stack: [frame | st.stack]}, key))
    end
  end

  defp advance(%{cur: %{entries: [entry | more]} = cur} = frame, st) do
    cur = %{cur | entries: more}

    case expand(entry, cur, frame, st) do
      {:ok, pending, exposed} ->
        advance(%{frame | cur: %{cur | pending: pending, exposed: exposed}}, st)

      {:error, record} ->
        alt_failed(frame, record, st)
    end
  end

  defp advance(%{cur: %{entries: [], pending: []} = cur} = frame, st) do
    case call_user(
           cur.body,
           [elem(frame.key, 2), cur.deps, st.context],
           :computation,
           frame,
           cur,
           st
         ) do
      {:ok, {:ok, value}} ->
        loop(%{
          st
          | values: Map.put(st.values, frame.key, value),
            in_progress: Map.delete(st.in_progress, frame.key)
        })

      {:ok, {:error, reason}} ->
        alt_failed(
          frame,
          computation_record(:user_term, format_reason(reason), reason, nil),
          st
        )

      {:ok, other} ->
        alt_failed(
          frame,
          computation_record(:bad_return, format_reason(other), other, nil),
          st
        )

      {:raised, record} ->
        alt_failed(frame, record, st)
    end
  end

  defp alt_failed(%{cur: %{name: name}} = frame, record, st) do
    attempts =
      Map.update(st.attempts, frame.key, %{name => record}, &Map.put(&1, name, record))

    advance(%{frame | cur: nil}, %{st | attempts: attempts})
  end

  defp expand({:key, term, key}, cur, _frame, _st) do
    {:ok, [{term, key}], cur.exposed}
  end

  defp expand({:alias, pairs}, cur, _frame, _st) do
    {:ok, pairs, cur.exposed}
  end

  defp expand({:fun, fun}, cur, frame, st) do
    {ns, _, params} = frame.key

    case call_user(fun, [params, cur.deps, st.context], :deps, frame, cur, st) do
      {:ok, result} -> dynamic_deps(result, ns, {fun, result, cur, frame, st})
      {:raised, record} -> {:error, record}
    end
  end

  defp dynamic_deps(result, ns, {_, _, cur, _, st} = ctx) do
    exposures = parse_dynamic(result, ns, ctx)

    Enum.each(exposures, fn {_, {kns, name, _} = key, _} ->
      if !is_map_key(st.rules, {kns, name}) do
        dynamic_error({:unknown_rule, key}, ctx)
      end
    end)

    exposed =
      Enum.reduce(exposures, cur.exposed, fn exposure, acc ->
        case expose(acc, exposure) do
          {:ok, acc} -> acc
          {:error, reason} -> dynamic_error(reason, ctx)
        end
      end)

    {:ok, Enum.map(exposures, fn {exposed, key, _} -> {exposed, key} end), exposed}
  end

  defp parse_dynamic(result, ns, ctx) when is_map(result) do
    result
    |> ordered_pairs()
    |> Enum.map(fn {alias, term} -> {alias, dynamic_key(term, ns, ctx), :alias} end)
  end

  defp parse_dynamic(result, ns, ctx) when is_list(result) do
    Enum.map(result, fn term ->
      {term, dynamic_key(term, ns, ctx), :key}
    end)
  end

  defp parse_dynamic(result, ns, ctx) do
    parse_dynamic([result], ns, ctx)
  end

  defp dynamic_key(term, ns, ctx) do
    case parse_key(term, ns) do
      {:ok, key} -> key
      {:error, reason} -> dynamic_error(reason, ctx)
    end
  end

  @spec dynamic_error(term, tuple) :: no_return
  defp dynamic_error(reason, {fun, result, cur, frame, st}) do
    error = %GraphError{
      rule: rule_of(frame.key),
      key: frame.key,
      alternative: cur.name,
      reason: {:bad_return, :deps, fun, result, reason}
    }

    throw({:graph_error, error, st})
  end

  defp cycle_error(key, frame, st) do
    stack = [frame | st.stack] |> Enum.map(& &1.key) |> :lists.reverse()

    %GraphError{
      rule: rule_of(frame.key),
      key: frame.key,
      alternative: frame.cur.name,
      reason: {:cycle, key, stack}
    }
  end

  defp rule_of({ns, name, _}) do
    {ns, name}
  end

  # -- Calling user code -----------------------------------------------------

  defp call_user(fun, args, kind, frame, cur, st) do
    meta = %{key: frame.key, alternative: cur.name}
    {:ok, invoke(Middleware.chain(st.middlewares, kind, meta, innermost_call(fun, args)))}
  catch
    kind, payload ->
      reason = Exception.normalize(kind, payload, __STACKTRACE__)

      message =
        case kind do
          :error -> format_reason({reason, __STACKTRACE__})
          _ -> format_reason(reason)
        end

      {:raised,
       computation_record(kind, message, reason, format_stacktrace(__STACKTRACE__))}
  end

  defp format_reason(reason) do
    Ark.Error.to_string(reason)
  catch
    kind, payload ->
      "#{inspect(reason)} (could not be formatted: #{kind}: #{inspect(payload)})"
  end

  defp format_stacktrace(stacktrace) do
    stacktrace
    |> Enum.map(fn
      {m, f, args, location} when is_list(args) -> {m, f, length(args), location}
      entry -> entry
    end)
    |> Exception.format_stacktrace()
  end

  defp innermost_call(fun, args) when is_function(fun) do
    {fun, args}
  end

  defp innermost_call({m, f, extra}, args) do
    {m, f, args ++ extra}
  end

  defp invoke({fun, args}) do
    apply(fun, args)
  end

  defp invoke({m, f, args}) do
    apply(m, f, args)
  end

  defp computation_record(kind, message, reason, stacktrace) do
    {:computation_error,
     %{
       at: DateTime.utc_now(),
       kind: kind,
       message: message,
       stacktrace: stacktrace,
       reason: reason
     }}
  end

  # -- Errors ----------------------------------------------------------------

  @doc false
  def format_key({:default, name, params}) when params == %{} do
    inspect(name)
  end

  def format_key({:default, name, params}) do
    inspect({name, params})
  end

  def format_key(key) do
    inspect(key)
  end

  @doc false
  def format_identity({:default, name}) do
    inspect(name)
  end

  def format_identity(identity) do
    inspect(identity)
  end

  @spec graph_error!(term, keyword) :: no_return
  defp graph_error!(reason, fields) do
    raise struct!(GraphError, [reason: reason] ++ fields)
  end
end
