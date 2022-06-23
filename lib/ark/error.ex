defmodule Ark.Error do
  @doc false
  def __ark__(:doc) do
    """
    This module provides function to work errors as data.
    """
  end

  import Kernel, except: [to_string: 1]

  defmacro reason(tag, data) do
    quote do
      {__MODULE__, unquote(tag), unquote(data)}
    end
  end

  @spec to_iodata(any) :: iodata()
  def to_iodata(reason)

  def to_iodata({:error, e}),
    do: to_iodata(e)

  def to_iodata({:shutdown, e}),
    do: ["(shutdown) ", to_iodata(e)]

  case Code.ensure_loaded(Ecto.Changeset) do
    {:module, _} ->
      def to_iodata(%Ecto.InvalidChangesetError{changeset: changeset, action: action}) do
        [
          "could not perform changeset action ",
          inspect(action),
          " ",
          to_iodata(changeset)
        ]
      end

      def to_iodata(%Ecto.Changeset{} = changeset) do
        details =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {key, value}, acc ->
              String.replace(acc, "%{#{key}}", inspect(value))
            end)
          end)
          |> Enum.map(fn {field, field_msgs} ->
            joined_errors = Enum.intersperse(field_msgs, ", ")
            [Atom.to_string(field), ": ", joined_errors]
          end)
          |> Enum.intersperse(" ; ")
          |> :lists.reverse()

        [
          "invalid changeset for ",
          inspect(changeset.data.__struct__),
          ", ",
          details
        ]
      end

    {:error, _} ->
      nil
  end

  def to_iodata({%{__exception__: true} = e, stack}) when is_list(stack),
    do: Exception.format_banner(:error, e, stack)

  def to_iodata(%{__exception__: true} = e),
    do: Exception.message(e)

  def to_iodata(%struct{message: message}) when is_binary(message),
    do: "#{inspect(struct)}: #{message}"

  def to_iodata(message) when is_binary(message),
    do: message

  def to_iodata({module, tag, data}) when is_atom(module) and is_atom(tag) do
    if function_exported?(module, :format_reason, 2),
      do: module.format_reason(tag, data),
      else: format_fallback(module, tag, data)
  end

  def to_iodata(other), do: inspect(other)

  def to_string(reason), do: reason |> to_iodata |> :erlang.iolist_to_binary()

  if Mix.env() != :prod do
    def format_fallback(module, tag, data) do
      IO.warn("""
      undefined function or function clause error when calling #{inspect(module)}.format_reason/2

      Please provide an implementation to suppress this warning.

        @doc false
        @spec format_reason(term, term) :: iodata
        def format_reason(#{inspect(tag)}, #{inspect(data)}) do
          # ...
        end

        def format_reason(other, data) do
          #{inspect(__MODULE__)}.format_fallback(__MODULE__, other, data)
        end

      """)

      "#{inspect({tag, data})}"
    end
  else
    def format_fallback(module, tag, data) do
      inspect({module, tag, data})
    end
  end

  defmacro log_error(error, metadata \\ []) do
    quote do
      require Logger
      Logger.error(unquote(__MODULE__).to_string(unquote(error)), unquote(metadata))
    end
  end

  defmacro debug_error(error, metadata \\ []) do
    quote do
      require Logger
      Logger.debug(unquote(__MODULE__).to_string(unquote(error)), unquote(metadata))
    end
  end
end
