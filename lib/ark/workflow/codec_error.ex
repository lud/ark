defmodule Ark.Workflow.CodecError do
  alias Ark.Workflow.GraphError

  @enforce_keys [:direction, :reason]
  defexception [:key, :reason, :direction]

  @impl true
  def message(%{key: nil} = e) do
    "cannot #{e.direction} data: #{format_reason(e.reason)}"
  end

  def message(e) do
    "cannot #{e.direction} value of #{GraphError.format_key(e.key)}: " <>
      format_reason(e.reason, e.direction)
  end

  defp format_reason({:bad_dump_term, term}, :dump) do
    "#{inspect(term)} cannot be persisted, " <>
      "values must not hold pids, ports, references or functions"
  end

  defp format_reason(e, direction) when is_exception(e) do
    "the #{inspect(direction)} callback raised: #{Exception.message(e)}"
  end

  defp format_reason(other, _direction) do
    format_reason(other)
  end

  defp format_reason({:unknown_rules, identities}) do
    "it holds records of rules that are not registered: " <>
      Enum.map_join(identities, ", ", &GraphError.format_identity/1)
  end

  defp format_reason({:malformed_failure, raw}) do
    "malformed failure record #{inspect(raw)}"
  end

  defp format_reason(e) when is_exception(e) do
    Exception.message(e)
  end

  defp format_reason(other) do
    inspect(other)
  end
end
