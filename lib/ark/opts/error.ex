defmodule Ark.Opts.Error do
  @moduledoc """
  Returned or raised by `Ark.Opts.validate/4` and `Ark.Opts.validate!/4` for
  invalid options.

  The fields are:

  * `:kind` - One of `:invalid_value`, `:unknown_option`, `:duplicate_option`,
    `:missing_option` or `:invalid_options` (options that are not a keyword
    list or a map).
  * `:path` - The list of keys leading to the invalid option, from the
    outermost one. Nested validations prepend their option key, and
    `Ark.Opts.list_of/2` prepends the index of the element. The path is empty
    for `:invalid_options` at the top level.
  * `:value` - The invalid value, for `:invalid_value` and `:invalid_options`.
  * `:reason` - For `:invalid_value`, the reason returned by the validator: a
    string describing the expected values, or any other term.
  * `:subject` - The subject given to `Ark.Opts.validate/4`, naming the caller.
  """
  defexception [:kind, :path, :value, :reason, :subject]

  @type t :: %__MODULE__{}

  @impl true
  def message(%{kind: :invalid_value, reason: reason} = e) when is_binary(reason) do
    "invalid value for option #{format_path(e.path)}#{in_subject(e.subject)}, " <>
      "expected #{reason}, got: #{inspect(e.value)}"
  end

  def message(%{kind: :invalid_value} = e) do
    "invalid value for option #{format_path(e.path)}#{in_subject(e.subject)}: " <>
      format_reason(e.reason)
  end

  def message(%{kind: :unknown_option} = e) do
    "unknown option #{format_path(e.path)}#{in_subject(e.subject)}"
  end

  def message(%{kind: :duplicate_option} = e) do
    "duplicate option #{format_path(e.path)}#{in_subject(e.subject)}"
  end

  def message(%{kind: :missing_option} = e) do
    "missing required option #{format_path(e.path)}#{in_subject(e.subject)}"
  end

  def message(%{kind: :invalid_options} = e) do
    "expected #{options_name(e.path)}#{in_subject(e.subject)} to be a keyword list or a map, " <>
      "got: #{inspect(e.value)}"
  end

  @doc false
  def prepend(%__MODULE__{path: path} = e, key) do
    %{e | path: [key | path]}
  end

  defp options_name([]) do
    "options"
  end

  defp options_name(path) do
    "option #{format_path(path)}"
  end

  defp format_path(path) do
    Enum.map_join(path, "/", &inspect/1)
  end

  @doc false
  def in_subject(nil) do
    ""
  end

  def in_subject(subject) when is_binary(subject) do
    " in " <> subject
  end

  def in_subject(subject) do
    " in " <> inspect(subject)
  end

  defp format_reason(reason) when is_binary(reason) do
    reason
  end

  defp format_reason(reason) when is_exception(reason) do
    Exception.message(reason)
  end

  defp format_reason({:any_of, reasons}) when is_list(reasons) do
    Enum.map_join(reasons, " or ", &format_reason/1)
  end

  defp format_reason(reason)
       when is_list(reason) or is_nil(reason) or is_boolean(reason) do
    inspect(reason)
  end

  defp format_reason(reason) do
    case String.Chars.impl_for(reason) do
      nil -> inspect(reason)
      _ -> to_string(reason)
    end
  end
end
