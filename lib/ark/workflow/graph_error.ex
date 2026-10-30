defmodule Ark.Workflow.GraphError do
  defexception [:rule, :key, :alternative, :reason]

  @impl true
  def message(e) do
    format_reason(e.reason) <> location(e)
  end

  defp format_reason({:invalid_key, given}) do
    "invalid key #{inspect(given)}"
  end

  defp format_reason({:invalid_params, {ns, name} = given})
       when is_atom(ns) and is_atom(name) do
    "invalid params in #{inspect(given)}, " <>
      "a key without params is written #{inspect({ns, name, %{}})}"
  end

  defp format_reason({:invalid_params, given}) do
    "invalid params in #{inspect(given)}, " <>
      "params must be a map without pids, ports, references or functions"
  end

  defp format_reason({:unknown_rule, key}) do
    "no rule registered for #{format_key(key)}"
  end

  defp format_reason({:shadowing, {exposed, key_a, _}, {exposed, key_b, _}}) do
    "#{format_key(key_a)} and #{format_key(key_b)} are both exposed as #{inspect(exposed)}"
  end

  defp format_reason({:invalid_identity, given}) do
    "invalid rule identity #{inspect(given)}"
  end

  defp format_reason({:duplicate_rule, identity}) do
    "rule #{format_identity(identity)} is already registered"
  end

  defp format_reason({:invalid_rule, error}) do
    "invalid rule: " <> Exception.message(error)
  end

  defp format_reason({:invalid_namespace, given}) do
    "invalid namespace #{inspect(given)}"
  end

  defp format_reason({:bad_return, :add_ns, _fun, retval, :not_a_graph}) do
    "add_ns callback must return a workflow, got: #{inspect(retval)}"
  end

  defp format_reason({:bad_return, :deps, _fun, retval, reason}) do
    "a dependency function returned #{inspect(retval)}: #{format_reason(reason)}" <>
      ok_hint(retval)
  end

  defp format_reason({:cycle, key, stack}) do
    "dependency cycle on #{format_key(key)}: " <>
      Enum.map_join(stack ++ [key], " -> ", &format_key/1)
  end

  defp ok_hint({:ok, _}) do
    ". Dependency functions return keys directly, not an :ok tuple"
  end

  defp ok_hint(_) do
    ""
  end

  defp location(%{alternative: nil, rule: nil}) do
    ""
  end

  defp location(%{alternative: nil, rule: rule}) do
    " (rule #{format_identity(rule)})"
  end

  defp location(%{alternative: alt, key: nil, rule: rule}) do
    " (alternative #{inspect(alt)} of #{format_identity(rule)})"
  end

  defp location(%{alternative: alt, key: key}) do
    " (alternative #{inspect(alt)} of #{format_key(key)})"
  end

  defp format_key({:default, name, params}) when params == %{} do
    inspect(name)
  end

  defp format_key({:default, name, params}) do
    inspect({name, params})
  end

  defp format_key(key) do
    inspect(key)
  end

  defp format_identity({:default, name}) do
    inspect(name)
  end

  defp format_identity(identity) do
    inspect(identity)
  end
end
