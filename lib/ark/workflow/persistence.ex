defmodule Ark.Workflow.Persistence do
  @moduledoc false

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

  def dump(rules, store) do
    %{results: results, attempts: attempts} = store

    entries =
      (Map.keys(results) ++ Map.keys(attempts))
      |> Enum.uniq()
      |> Enum.map(&dump_entry(&1, rules, store))
      |> Enum.sort()

    {:ok, %{"version" => @version, "entries" => entries}}
  catch
    {:codec_error, %CodecError{} = e} -> {:error, e}
  end

  defp dump_entry({ns, name, _} = key, rules, store) do
    entry = %{"key" => dump_key(key)}

    entry =
      case store.results do
        %{^key => {:ok, value}} ->
          rule = Map.fetch!(rules, {ns, name})
          Map.put(entry, "result", %{"ok" => dump_value(value, key, rule)})

        %{^key => {:failed, record}} ->
          Map.put(entry, "result", %{"failed" => dump_record(record)})

        _ ->
          entry
      end

    case store.attempts do
      %{^key => by_alt} ->
        attempts =
          Map.new(by_alt, fn {alt, record} -> {dump_name(alt), dump_record(record)} end)

        Map.put(entry, "attempts", attempts)

      _ ->
        entry
    end
  end

  defp dump_value(value, key, rule) do
    normal =
      case rule do
        %{dump: dump} ->
          case call_codec(dump, value) do
            {:ok, normal} -> normal
            {:error, e} -> codec_error!(:dump, key, e)
          end

        _ ->
          value
      end

    encode!(normal, key)
  end

  defp dump_record({:computation_error, cleaned_error}) do
    %{at: at, kind: kind, message: message, stacktrace: stacktrace} = cleaned_error

    %{
      "computation_error" => %{
        "at" => DateTime.to_iso8601(at),
        "kind" => Atom.to_string(kind),
        "message" => encode!(message, nil),
        "stacktrace" => encode!(stacktrace, nil)
      }
    }
  end

  defp dump_record({:dep_failed, dep_key}) do
    %{"dep_failed" => dump_key(dep_key)}
  end

  defp dump_record({:all_alternatives_failed, names}) do
    %{"all_alternatives_failed" => Enum.map(names, &dump_name/1)}
  end

  defp dump_key({ns, name, params} = key) do
    %{"ns" => dump_name(ns), "name" => dump_name(name), "params" => encode!(params, key)}
  end

  defp dump_name(name) when is_atom(name) do
    Atom.to_string(name)
  end

  defp dump_name(name) when is_binary(name) do
    name
  end

  defp encode!(term, key) do
    case Codec.encode(term) do
      {:ok, encoded} -> encoded
      {:error, reason} -> codec_error!(:dump, key, reason)
    end
  end

  def load(rules, %{"version" => @version, "entries" => entries}) when is_list(entries) do
    index =
      Map.new(rules, fn {{ns, name} = identity, _} ->
        {{dump_name(ns), dump_name(name)}, identity}
      end)

    with :ok <- check_known_rules(entries, index) do
      store =
        Enum.reduce(
          entries,
          %{results: %{}, attempts: %{}},
          &load_entry(&1, &2, rules, index)
        )

      {:ok, store}
    end
  catch
    {:codec_error, %CodecError{} = e} -> {:error, e}
  end

  def load(_rules, data) do
    {:error, %CodecError{direction: :load, reason: {:malformed, data}}}
  end

  defp check_known_rules(entries, index) do
    unknown =
      entries
      |> Enum.map(&raw_identity/1)
      |> Enum.reject(&is_map_key(index, &1))
      |> Enum.uniq()
      |> Enum.map(fn {ns, name} -> {maybe_atom(ns), maybe_atom(name)} end)

    case unknown do
      [] -> :ok
      _ -> {:error, %CodecError{direction: :load, reason: {:unknown_rules, unknown}}}
    end
  end

  defp raw_identity(%{"key" => %{"ns" => ns, "name" => name, "params" => _}})
       when is_binary(ns) and is_binary(name) do
    {ns, name}
  end

  defp raw_identity(entry) do
    malformed!(entry)
  end

  defp load_entry(entry, store, rules, index) do
    %{"key" => %{"ns" => ns, "name" => name, "params" => raw_params}} = entry
    {rule_ns, rule_name} = identity = Map.fetch!(index, {ns, name})
    key = {rule_ns, rule_name, decode!(raw_params, nil)}

    if is_map_key(store.results, key) or is_map_key(store.attempts, key) do
      throw({:codec_error, %CodecError{direction: :load, reason: {:duplicate_key, key}}})
    end

    store
    |> load_result(entry, key, Map.fetch!(rules, identity))
    |> load_attempts(entry, key)
  end

  defp load_result(store, %{"result" => %{"ok" => raw_value}}, key, rule) do
    put_in(store, [:results, key], {:ok, load_value(raw_value, key, rule)})
  end

  defp load_result(store, %{"result" => %{"failed" => raw_record}}, key, _rule) do
    put_in(store, [:results, key], {:failed, load_record(raw_record)})
  end

  defp load_result(_store, %{"result" => _} = entry, _key, _rule) do
    malformed!(entry)
  end

  defp load_result(store, _entry, _key, _rule) do
    store
  end

  defp load_attempts(store, %{"attempts" => raw_attempts}, key)
       when is_map(raw_attempts) do
    by_alt =
      Map.new(raw_attempts, fn {raw_alt, raw_record} ->
        {maybe_atom(raw_alt), load_record(raw_record)}
      end)

    put_in(store, [:attempts, key], by_alt)
  end

  defp load_attempts(_store, %{"attempts" => _} = entry, _key) do
    malformed!(entry)
  end

  defp load_attempts(store, _entry, _key) do
    store
  end

  defp load_value(raw_value, key, rule) do
    normal = decode!(raw_value, key)

    case rule do
      %{load: load} ->
        case call_codec(load, normal) do
          {:ok, value} -> value
          {:error, e} -> codec_error!(:load, key, e)
        end

      _ ->
        normal
    end
  end

  defp load_record(%{"computation_error" => raw_error} = raw) do
    with %{
           "at" => raw_at,
           "kind" => raw_kind,
           "message" => raw_message,
           "stacktrace" => raw_st
         } <-
           raw_error,
         true <- is_binary(raw_at),
         {:ok, at, _} <- DateTime.from_iso8601(raw_at),
         {:ok, kind} <- Map.fetch(@kinds, raw_kind),
         message when is_binary(message) <- decode!(raw_message, nil),
         stacktrace when is_binary(stacktrace) or is_nil(stacktrace) <-
           decode!(raw_st, nil) do
      {:computation_error,
       %{at: at, kind: kind, message: message, stacktrace: stacktrace, reason: nil}}
    else
      _ -> malformed!(raw)
    end
  end

  defp load_record(%{
         "dep_failed" => %{"ns" => ns, "name" => name, "params" => raw_params}
       })
       when is_binary(ns) and is_binary(name) do
    {:dep_failed, {maybe_atom(ns), maybe_atom(name), decode!(raw_params, nil)}}
  end

  defp load_record(%{"all_alternatives_failed" => names} = raw) when is_list(names) do
    if Enum.all?(names, &is_binary/1) do
      {:all_alternatives_failed, Enum.map(names, &maybe_atom/1)}
    else
      malformed!(raw)
    end
  end

  defp load_record(raw) do
    malformed!(raw)
  end

  defp decode!(encoded, key) do
    case Codec.decode(encoded) do
      {:ok, term} -> term
      :error -> codec_error!(:load, key, {:undecodable, encoded})
    end
  end

  defp maybe_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> string
  end

  defp maybe_atom(other) do
    malformed!(other)
  end

  defp call_codec(codec, value) do
    {:ok, do_call_codec(codec, value)}
  rescue
    e -> {:error, e}
  catch
    _kind, e -> {:error, e}
  end

  defp do_call_codec(fun, value) when is_function(fun) do
    fun.(value)
  end

  defp do_call_codec({m, f, args}, value) do
    apply(m, f, [value | args])
  end

  @spec malformed!(term) :: no_return()
  defp malformed!(raw) do
    throw({:codec_error, %CodecError{direction: :load, reason: {:malformed, raw}}})
  end

  @spec codec_error!(:dump | :load, term, term) :: no_return()
  defp codec_error!(direction, key, reason) do
    throw({:codec_error, %CodecError{direction: direction, key: key, reason: reason}})
  end
end
