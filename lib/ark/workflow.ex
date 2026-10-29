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
      graph_error!(
        :duplicate_rule,
        "rule #{format_identity({ns, name})} is already registered",
        key: {ns, name}
      )
    end

    %{wf | rules: Map.put(wf.rules, {ns, name}, parse_rule(rule, ns, {ns, name}))}
  end

  def add_ns(%__MODULE__{} = wf, ns, callback) when is_function(callback, 1) do
    if !valid_name?(ns) do
      graph_error!(:invalid_namespace, "invalid namespace #{inspect(ns)}", value: ns)
    end

    case callback.(%{wf | ns: ns}) do
      %__MODULE__{} = inner ->
        %{inner | ns: wf.ns}

      other ->
        graph_error!(
          :invalid_namespace_callback,
          "add_ns callback must return a workflow, got: #{inspect(other)}",
          value: other
        )
    end
  end

  defp parse_identity(name, ns) when is_atom(name) do
    parse_identity({ns, name}, ns)
  end

  defp parse_identity({ns, name}, _) do
    if valid_name?(ns) and valid_name?(name) do
      {ns, name}
    else
      invalid_identity!({ns, name})
    end
  end

  defp parse_identity(other, _) do
    invalid_identity!(other)
  end

  @spec invalid_identity!(term) :: no_return
  defp invalid_identity!(identity) do
    graph_error!(:invalid_rule, "invalid rule identity #{inspect(identity)}",
      value: identity
    )
  end

  defp valid_name?(term) do
    is_atom(term) and term not in [nil, true, false]
  end

  defp parse_rule(rule, ns, identity) when is_map(rule) do
    check_keys!(rule, @rule_keys, "rule", identity)

    alts =
      case rule do
        %{alts: alts} -> parse_alts(alts, ns, identity)
        _ -> invalid_rule!(identity, "missing :alts", nil)
      end

    %{
      alts: alts,
      dump: parse_codec(rule, :dump, identity),
      load: parse_codec(rule, :load, identity)
    }
  end

  defp parse_rule(rule, _ns, identity) do
    invalid_rule!(identity, "expected a map", rule)
  end

  defp check_keys!(map, allowed, what, identity) do
    case Map.keys(map) -- allowed do
      [] ->
        :ok

      unknown ->
        invalid_rule!(identity, "unknown #{what} keys: #{inspect(unknown)}", unknown)
    end
  end

  @spec invalid_rule!(term, String.t(), term) :: no_return
  defp invalid_rule!(identity, reason, value) do
    graph_error!(:invalid_rule, "invalid rule #{inspect(identity)}: #{reason}",
      key: identity,
      value: value
    )
  end

  defp parse_codec(rule, field, identity) do
    case rule do
      %{^field => fun} ->
        if callable?(fun, 1) do
          fun
        else
          invalid_rule!(
            identity,
            "#{inspect(field)} must be a function of arity 1 or a tuple",
            fun
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
        {name, alt} when is_map(alt) ->
          if !valid_name?(name) do
            invalid_rule!(identity, "invalid alternative name #{inspect(name)}", name)
          end

          {name, parse_alt(name, alt, ns, identity)}

        other ->
          invalid_rule!(identity, "invalid alternative #{inspect(other)}", other)
      end)

    names = Enum.map(parsed, &elem(&1, 0))

    if length(names) != length(Enum.uniq(names)) do
      invalid_rule!(identity, "duplicate alternative names in #{inspect(names)}", names)
    end

    parsed
  end

  defp parse_alts(other, _ns, identity) do
    invalid_rule!(identity, ":alts must be a non-empty keyword list", other)
  end

  defp parse_alt(name, alt, ns, identity) do
    check_keys!(alt, @alt_keys, "alternative #{inspect(name)}", identity)

    with {:ok, deps} <- Map.fetch(alt, :deps),
         {:ok, body} <- Map.fetch(alt, :body) do
      if not is_list(deps) do
        invalid_rule!(
          identity,
          "alternative #{inspect(name)}: :deps must be a list",
          deps
        )
      end

      if !callable?(body, 3) do
        invalid_rule!(
          identity,
          "alternative #{inspect(name)}: :body must be a function of arity 3 or a tuple",
          body
        )
      end

      entries = Enum.map(deps, &parse_dep(&1, ns, identity, name))
      exposed = check_shadowing!(entries, identity, name)
      %{deps: entries, body: body, exposed: exposed}
    else
      :error ->
        invalid_rule!(identity, "alternative #{inspect(name)} needs :deps and :body", alt)
    end
  end

  defp parse_dep(fun, _ns, identity, alt) when is_function(fun) do
    if is_function(fun, 3) do
      {:fun, fun}
    else
      invalid_dep!(identity, alt, fun)
    end
  end

  defp parse_dep({m, f, args} = mfa, _ns, _identity, _alt)
       when is_atom(m) and is_atom(f) and is_list(args) do
    {:fun, mfa}
  end

  defp parse_dep(map, ns, identity, alt) when is_map(map) do
    {:alias,
     Enum.map(ordered_pairs(map), fn {a, k} ->
       {a, parse_dep_key(k, ns, identity, alt)}
     end)}
  end

  defp parse_dep(term, ns, identity, alt) do
    {:key, term, parse_dep_key(term, ns, identity, alt)}
  end

  defp parse_dep_key(term, ns, identity, alt) do
    case parse_key(term, ns) do
      {:ok, key} -> key
      :error -> invalid_dep!(identity, alt, term)
    end
  end

  @spec invalid_dep!(term, atom, term) :: no_return
  defp invalid_dep!(identity, alt, term) do
    graph_error!(
      :invalid_dependency,
      "invalid dependency #{inspect(term)} in alternative #{inspect(alt)} of #{format_identity(identity)}",
      key: identity,
      alternative: alt,
      value: term
    )
  end

  defp check_shadowing!(entries, identity, alt) do
    Enum.reduce(entries, %{}, fn
      {:fun, _}, acc ->
        acc

      {:key, term, key}, acc ->
        expose!(acc, term, key, identity, alt)

      {:alias, pairs}, acc ->
        Enum.reduce(pairs, acc, fn {a, key}, acc ->
          expose!(acc, a, key, identity, alt)
        end)
    end)
  end

  defp expose!(acc, exposed, key, identity, alt) do
    case acc do
      %{^exposed => ^key} ->
        acc

      %{^exposed => other} ->
        graph_error!(
          :shadowing,
          "keys #{format_key(other)} and #{format_key(key)} are both exposed as " <>
            "#{inspect(exposed)} in alternative #{inspect(alt)} of #{format_identity(identity)}",
          key: key,
          alternative: alt,
          value: exposed
        )

      _ ->
        Map.put(acc, exposed, key)
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
      :error
    end
  end

  defp parse_key({name, params}, ns) do
    if valid_name?(name) and valid_params?(params) do
      {:ok, {ns, name, params}}
    else
      :error
    end
  end

  defp parse_key({kns, name, params}, _ns) do
    if valid_name?(kns) and valid_name?(name) and valid_params?(params) do
      {:ok, {kns, name, params}}
    else
      :error
    end
  end

  defp parse_key(_, _ns) do
    :error
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
          {:error, unknown_rule(full, nil)}
        end

      :error ->
        {:error,
         %GraphError{
           kind: :invalid_key,
           message: "invalid key #{inspect(key)}",
           value: key
         }}
    end
  end

  defp unknown_rule({ns, name, _} = key, alt) do
    %GraphError{
      kind: :unknown_rule,
      message: "no rule registered for #{format_identity({ns, name})}",
      key: key,
      alternative: alt
    }
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
        {:failed, target, st} -> {:error, computation_error(target, st), save(wf, st)}
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
       %GraphError{
         kind: :unknown_rule,
         message:
           "alternative #{inspect(alt)} of #{format_identity(identity)} depends on #{format_key(key)}, " <>
             "but no rule #{format_identity({ns, name})} is registered",
         key: key,
         alternative: alt
       }}
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
            unknown_rule(key, nil)
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
          computation_record(:user_term, user_term_message(reason), reason),
          st
        )

      {:ok, other} ->
        alt_failed(frame, computation_record(:bad_return, inspect(other), other), st)

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
      {:ok, result} -> dynamic_deps(result, ns, cur, frame, st)
      {:raised, record} -> {:error, record}
    end
  end

  defp dynamic_deps(result, ns, cur, frame, st) do
    pairs =
      parse_dynamic(result, ns, {result, cur, frame, st})

    Enum.each(pairs, fn {_, {kns, name, _} = key} ->
      if !is_map_key(st.rules, {kns, name}) do
        message =
          "dependency #{format_key(key)} has no registered rule" <> ok_hint(result)

        dynamic_error(:unknown_rule, message, result, cur, frame, st)
      end
    end)

    exposed =
      Enum.reduce(pairs, cur.exposed, fn {exposed, key}, acc ->
        case acc do
          %{^exposed => ^key} ->
            acc

          %{^exposed => other} ->
            message =
              "keys #{format_key(other)} and #{format_key(key)} are both exposed as " <>
                "#{inspect(exposed)} in alternative #{inspect(cur.name)} of #{format_key(frame.key)}"

            dynamic_error(:shadowing, message, result, cur, frame, st)

          _ ->
            Map.put(acc, exposed, key)
        end
      end)

    {:ok, pairs, exposed}
  end

  defp parse_dynamic(result, ns, ctx) when is_map(result) do
    result
    |> ordered_pairs()
    |> Enum.map(fn {alias, term} -> {alias, dynamic_key(term, ns, ctx)} end)
  end

  defp parse_dynamic(result, ns, ctx) when is_list(result) do
    Enum.map(result, fn term ->
      {term, dynamic_key(term, ns, ctx)}
    end)
  end

  defp parse_dynamic(result, ns, ctx) do
    parse_dynamic([result], ns, ctx)
  end

  defp dynamic_key(term, ns, ctx) do
    case parse_key(term, ns) do
      {:ok, key} ->
        key

      :error ->
        {result, cur, frame, st} = ctx

        dynamic_error(
          :invalid_dependency,
          "a dependency function returned an invalid dependency: #{inspect(term)}" <>
            ok_hint(result),
          result,
          cur,
          frame,
          st
        )
    end
  end

  defp ok_hint({:ok, _}) do
    ". Dependency functions return keys directly, not an :ok tuple"
  end

  defp ok_hint(_) do
    ""
  end

  @spec dynamic_error(atom, String.t(), term, map, map, map) :: no_return
  defp dynamic_error(kind, message, result, cur, frame, st) do
    error = %GraphError{
      kind: kind,
      message:
        "#{message} (alternative #{inspect(cur.name)} of #{format_key(frame.key)})",
      key: frame.key,
      alternative: cur.name,
      value: result
    }

    throw({:graph_error, error, st})
  end

  defp cycle_error(key, frame, st) do
    stack = [frame | st.stack] |> Enum.map(& &1.key) |> :lists.reverse()

    %GraphError{
      kind: :cycle,
      message: "dependency cycle on #{format_key(key)}",
      key: key,
      stack: stack
    }
  end

  # -- Calling user code -----------------------------------------------------

  defp call_user(fun, args, kind, frame, cur, st) do
    meta = %{key: frame.key, alternative: cur.name}
    {:ok, invoke(Middleware.chain(st.middlewares, kind, meta, innermost_call(fun, args)))}
  catch
    kind, payload ->
      {:raised,
       computation_record(
         kind,
         format_caught(kind, payload, __STACKTRACE__),
         Exception.normalize(kind, payload, __STACKTRACE__)
       )}
  end

  defp format_caught(kind, payload, stacktrace) do
    {payload, stacktrace} = Exception.blame(kind, payload, stacktrace)
    Exception.format(kind, payload, stacktrace)
  catch
    kind2, payload2 ->
      "#{kind}: #{inspect(payload)} (could not be formatted: #{kind2}: #{inspect(payload2)})"
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

  defp computation_record(kind, message, reason) do
    {:computation_error,
     %{at: DateTime.utc_now(), kind: kind, message: message, reason: reason}}
  end

  defp user_term_message(reason) do
    if is_exception(reason) do
      safe_message(reason)
    else
      inspect(reason)
    end
  end

  defp safe_message(exception) do
    Exception.message(exception)
  catch
    _, _ -> inspect(exception)
  end

  # -- Errors ----------------------------------------------------------------

  defp computation_error(target, st) do
    causes = target |> causes(st) |> Enum.uniq_by(&{&1.key, &1.alternative})
    {lines, _} = describe(target, st, 1, %{})
    ComputationError.new(target, causes, render(lines))
  end

  defp causes(key, st) do
    case st.failed do
      %{^key => {:all_alternatives_failed, alts}} ->
        attempts = Map.get(st.attempts, key, %{})
        Enum.flat_map(alts, &alt_causes(key, &1, attempts, st))

      _ ->
        []
    end
  end

  defp alt_causes(key, alt, attempts, st) do
    case attempts do
      %{^alt => {:dep_failed, dep}} ->
        causes(dep, st)

      %{^alt => {:computation_error, error}} ->
        [%{key: key, alternative: alt, error: error}]

      _ ->
        []
    end
  end

  defp describe(key, st, depth, seen) do
    case st.failed do
      %{^key => {:all_alternatives_failed, alts}} ->
        attempts = Map.get(st.attempts, key, %{})
        seen = Map.put(seen, key, true)

        Enum.reduce(alts, {[{depth, "#{format_key(key)} failed:"}], seen}, fn alt,
                                                                              {lines,
                                                                               seen} ->
          describe_attempt(Map.get(attempts, alt), alt, st, depth + 1, lines, seen)
        end)
        |> then(fn {lines, seen} -> {:lists.reverse(lines), seen} end)

      _ ->
        {[], seen}
    end
  end

  defp describe_attempt({:dep_failed, dep}, alt, st, depth, lines, seen) do
    lines = [
      {depth, "alternative #{inspect(alt)}: dependency #{format_key(dep)} failed"} | lines
    ]

    if is_map_key(seen, dep) do
      {[{depth + 1, "(failure described above)"} | lines], seen}
    else
      {sub, seen} = describe(dep, st, depth + 1, seen)
      {:lists.reverse(sub, lines), seen}
    end
  end

  defp describe_attempt({:computation_error, error}, alt, _st, depth, lines, seen) do
    {[{depth, "alternative #{inspect(alt)}: #{error.kind}: #{error.message}"} | lines],
     seen}
  end

  defp describe_attempt(_, _alt, _st, _depth, lines, seen) do
    {lines, seen}
  end

  defp render(lines) do
    Enum.map_join(lines, "\n", fn {depth, text} ->
      pad = String.duplicate("  ", depth)
      pad <> String.replace(text, "\n", "\n" <> pad <> "  ")
    end)
  end

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

  @spec graph_error!(atom, String.t(), keyword) :: no_return
  defp graph_error!(kind, message, fields) do
    raise struct!(GraphError, [kind: kind, message: message] ++ fields)
  end
end
