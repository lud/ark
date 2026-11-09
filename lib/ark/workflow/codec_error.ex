defmodule Ark.Workflow.CodecError do
  @moduledoc """
  Error returned by `Ark.Workflow.dump/1` and `Ark.Workflow.load/2`.

  The exception holds the following fields:

  * `:direction` - `:dump` or `:load`.
  * `:key` - the full `{namespace, name, params}` key whose value could not be
    dumped or loaded, or `nil` when the problem concerns the data as a whole.
  * `:reason` - a tuple describing the problem, such as `{:bad_dump_term, term}`
    for a value holding a pid, port, reference or function, `{:malformed, data}`
    or `{:unknown_rules, identities}`, or the exception raised by a `:dump` or
    `:load` callback.
  """

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

  defp format_reason({:malformed, raw}) do
    "malformed data #{inspect(raw)}"
  end

  defp format_reason({:duplicate_key, key}) do
    "it holds two entries for #{GraphError.format_key(key)}"
  end

  defp format_reason({:undecodable, encoded}) do
    "#{inspect(encoded)} cannot be decoded, " <>
      "it is not encoded data or references an atom that does not exist"
  end

  defp format_reason(e) when is_exception(e) do
    Exception.message(e)
  end

  defp format_reason(other) do
    inspect(other)
  end
end
