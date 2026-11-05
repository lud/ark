defmodule Ark.Workflow.Persistence do
  @moduledoc false

  require Logger

  alias Ark.Workflow
  alias Ark.Workflow.Codec
  alias Ark.Workflow.CodecError

  @version 1
  @kinds %{
    "error" => :error,
    "throw" => :throw,
    "exit" => :exit,
    "user_term" => :user_term,
    "bad_return" => :bad_return
  }

  # -- Dump ------------------------------------------------------------------

  def dump(%Workflow{} = wf) do
    keys =
      Enum.uniq(Map.keys(wf.values) ++ Map.keys(wf.failed) ++ Map.keys(wf.attempts))

    {entries, etf_keys} =
      Enum.map_reduce(keys, [], fn key, etf_keys ->
        {entry, etf?} = dump_entry(wf, key)

        {entry, add_if(etf?, key, etf_keys)}
      end)

    warn_etf(wf, etf_keys)

    {:ok, %{"version" => @version, "entries" => Enum.sort(entries)}}
  catch
    {:codec_error, error} -> {:error, error}
  end

  defp add_if(true, key, keys) do
    [key | keys]
  end

  defp add_if(false, _key, keys) do
    keys
  end

  defp dump_entry(wf, {ns, name, params} = key) do
    base = %{"ns" => str(ns), "name" => str(name), "params" => Codec.encode(params)}
    rule = Map.fetch!(wf.rules, {ns, name})

    {entry, etf?} =
      case wf.values do
        %{^key => value} ->
          encoded = Codec.encode(dump_value(rule.dump, value, key))
          {Map.put(base, "value", encoded), Codec.etf?(encoded)}

        _ ->
          {base, false}
      end

    entry =
      case wf.failed do
        %{^key => record} -> Map.put(entry, "failure", enc_record(record))
        _ -> entry
      end

    attempts =
      wf.attempts
      |> Map.get(key, %{})
      |> Enum.map(fn {alt, record} ->
        %{"alt" => str(alt), "record" => enc_record(record)}
      end)
      |> Enum.sort()

    entry =
      if attempts == [] do
        entry
      else
        Map.put(entry, "attempts", attempts)
      end

    {entry, etf?}
  end

  defp dump_value(dump, value, key) do
    dumped =
      try do
        apply_codec(dump, value)
      catch
        kind, payload ->
          codec_error!(
            key,
            "the :dump function raised: #{Exception.format_banner(kind, payload)}"
          )
      end

    if !Workflow.valid_term?(dumped) do
      codec_error!(key, "the value contains a pid, port, reference or function")
    end

    dumped
  end

  defp apply_codec(nil, value) do
    value
  end

  defp apply_codec(fun, value) when is_function(fun, 1) do
    fun.(value)
  end

  defp apply_codec({m, f, extra}, value) do
    apply(m, f, [value | extra])
  end

  defp enc_record({:all_alternatives_failed, alts}) do
    %{"t" => "all_alternatives_failed", "alts" => Enum.map(alts, &str/1)}
  end

  defp enc_record({:dep_failed, key}) do
    %{"t" => "dep_failed", "key" => enc_key(key)}
  end

  defp enc_record(
         {:computation_error,
          %{at: at, kind: kind, message: message, stacktrace: stacktrace}}
       ) do
    %{
      "t" => "computation_error",
      "at" => DateTime.to_unix(at, :microsecond),
      "kind" => Atom.to_string(kind),
      "message" => Codec.encode(message),
      "stacktrace" => Codec.encode(stacktrace)
    }
  end

  defp enc_key({ns, name, params}) do
    %{"ns" => str(ns), "name" => str(name), "params" => Codec.encode(params)}
  end

  defp str(term) when is_atom(term) do
    Atom.to_string(term)
  end

  defp str(term) when is_binary(term) do
    term
  end

  defp warn_etf(%{dump_check: true}, [_ | _] = keys) do
    Logger.warning(
      "workflow dump: values stored as ETF instead of JSON for keys: " <>
        Enum.map_join(Enum.sort(keys), ", ", &Workflow.format_key/1)
    )
  end

  defp warn_etf(_, _) do
    :ok
  end

  @spec codec_error!(tuple, String.t()) :: no_return
  defp codec_error!(key, reason) do
    throw(
      {:codec_error,
       %CodecError{
         key: key,
         message: "cannot dump #{Workflow.format_key(key)}: #{reason}"
       }}
    )
  end

  # -- Load ------------------------------------------------------------------

  def load(%Workflow{} = wf, %{"version" => @version, "entries" => entries})
      when is_list(entries) do
    index = rule_index(wf)

    {values, failed, attempts, unknown} =
      Enum.reduce(entries, {%{}, %{}, %{}, []}, &load_entry(&1, wf, index, &2))

    case unknown do
      [] -> {:ok, %{wf | values: values, failed: failed, attempts: attempts}}
      _ -> {:error, unknown_rules(unknown)}
    end
  rescue
    e in [ArgumentError, MatchError, FunctionClauseError, KeyError, CaseClauseError] ->
      {:error, malformed(Exception.message(e))}
  catch
    {:codec_error, error} -> {:error, error}
  end

  def load(_wf, data) do
    {:error, malformed("unexpected data: #{inspect(data, limit: 5)}")}
  end

  defp rule_index(wf) do
    Map.new(wf.rules, fn {{ns, name}, _} -> {{str(ns), str(name)}, {ns, name}} end)
  end

  defp malformed(reason) do
    %CodecError{message: "cannot load workflow data: #{reason}"}
  end

  defp unknown_rules(unknown) do
    identities = unknown |> Enum.uniq() |> Enum.sort()

    %CodecError{
      reason: {:unknown_rules, identities},
      message:
        "cannot load workflow data: no rule is registered for the records of: " <>
          Enum.map_join(identities, ", ", &inspect/1)
    }
  end

  defp load_entry(
         %{"ns" => ns, "name" => name, "params" => params} = entry,
         wf,
         index,
         {values, failed, attempts, unknown}
       )
       when is_binary(ns) and is_binary(name) do
    case index do
      %{{^ns, ^name} => identity} ->
        rule = Map.fetch!(wf.rules, identity)
        key = {elem(identity, 0), elem(identity, 1), Codec.decode(params)}

        values = put_value(values, entry, rule, key)
        failed = put_failure(failed, entry, key)
        attempts = put_attempts(attempts, entry, key)

        {values, failed, attempts, unknown}

      _ ->
        {values, failed, attempts, [{existing_atom(ns), existing_atom(name)} | unknown]}
    end
  end

  defp load_entry(other, _, _, _) do
    throw({:codec_error, malformed("invalid entry: #{inspect(other, limit: 5)}")})
  end

  defp put_value(values, %{"value" => encoded}, rule, key) do
    Map.put(values, key, load_value(rule.load, encoded, key))
  end

  defp put_value(values, _entry, _rule, _key) do
    values
  end

  defp put_failure(failed, %{"failure" => record}, key) do
    Map.put(failed, key, dec_record(record))
  end

  defp put_failure(failed, _entry, _key) do
    failed
  end

  defp put_attempts(attempts, %{"attempts" => list}, key) when is_list(list) do
    Map.put(attempts, key, dec_attempts(list))
  end

  defp put_attempts(attempts, _entry, _key) do
    attempts
  end

  defp load_value(load, encoded, key) do
    apply_codec(load, Codec.decode(encoded))
  catch
    kind, payload ->
      throw(
        {:codec_error,
         %CodecError{
           key: key,
           message:
             "cannot load #{Workflow.format_key(key)}: " <>
               Exception.format_banner(kind, payload)
         }}
      )
  end

  defp dec_attempts(list) do
    Map.new(list, fn %{"alt" => alt, "record" => record} ->
      {existing_atom(alt), dec_record(record)}
    end)
  end

  defp dec_record(%{"t" => "all_alternatives_failed", "alts" => names})
       when is_list(names) do
    {:all_alternatives_failed, Enum.map(names, &existing_atom/1)}
  end

  defp dec_record(%{"t" => "dep_failed", "key" => key}) do
    {:dep_failed, dec_key(key)}
  end

  defp dec_record(%{
         "t" => "computation_error",
         "at" => at,
         "kind" => kind,
         "message" => message,
         "stacktrace" => stacktrace
       })
       when is_integer(at) do
    {:computation_error,
     %{
       at: DateTime.from_unix!(at, :microsecond),
       kind: Map.fetch!(@kinds, kind),
       message: Codec.decode(message),
       stacktrace: Codec.decode(stacktrace),
       reason: nil
     }}
  end

  defp dec_key(%{"ns" => ns, "name" => name, "params" => params}) do
    {existing_atom(ns), existing_atom(name), Codec.decode(params)}
  end

  defp existing_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end
end
