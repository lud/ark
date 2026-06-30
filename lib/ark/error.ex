defmodule Ark.Error do
  @moduledoc ~S"""
  Turns error reasons into human-readable text.

  Elixir code commonly returns errors as the `reason` in an `{:error, reason}`
  tuple, where `reason` can be a string, an exception, a changeset, or any term.
  `Ark.Error` renders any of these into a message you can log or show, without
  having to match on the shape first.

      iex> Ark.Error.to_string({:error, "database is down"})
      "database is down"

  `to_iodata/1` and `to_string/1` accept, among others:

    * a binary message, returned as-is
    * an exception struct, rendered with `Exception.message/1`
    * an `{exception, stacktrace}` pair, rendered as a banner
    * a nested `{:error, reason}` or `{:shutdown, reason}` tuple
    * an `Ecto.Changeset` or `Ecto.InvalidChangesetError`, when Ecto is loaded
    * any other term, rendered with `inspect/1`

  ### Custom error formatting

  An error can also be a `{module, tag, data}` triple, which lets a module
  render its own errors. When `module` exports `format_reason/2`, it is called
  with `tag` and `data` to produce the message:

      defmodule MyApp.Upload do
        @spec format_reason(term, term) :: iodata
        def format_reason(:too_large, size) do
          "file is too large: #{size} bytes"
        end

        def format_reason(other, data) do
          Ark.Error.format_fallback(__MODULE__, other, data)
        end
      end

      Ark.Error.to_string({MyApp.Upload, :too_large, 5_000_000})
      # => "file is too large: 5000000 bytes"

  `format_fallback/3` renders any tag the module does not handle, so a single
  catch-all clause covers every remaining case.

  ### Logging helpers

  `log_error/2` and `debug_error/2` format a reason and send it to `Logger` at
  the `:error` and `:debug` levels:

      require Ark.Error
      Ark.Error.log_error({:error, :timeout}, request_id: request_id)
  """

  @doc false
  def __ark__(:doc) do
    """
    This module provides function to work errors as data.
    """
  end

  import Kernel, except: [to_string: 1]

  @doc """
  Renders an error reason as `t:iodata/0`.

  Accepts the shapes listed in `Ark.Error`. Returning iodata avoids building
  intermediate strings, which is convenient when the result goes straight to
  `Logger` or `IO`.

      iex> IO.iodata_to_binary(Ark.Error.to_iodata({:shutdown, "node left"}))
      "(shutdown) node left"
  """
  @spec to_iodata(any) :: iodata()
  def to_iodata(reason)

  def to_iodata({:error, e}) do
    to_iodata(e)
  end

  def to_iodata({:shutdown, e}) do
    ["(shutdown) ", to_iodata(e)]
  end

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

  def to_iodata({%{__exception__: true} = e, stack}) when is_list(stack) do
    Exception.format_banner(:error, e, stack)
  end

  def to_iodata(%{__exception__: true} = e) do
    Exception.message(e)
  end

  def to_iodata(%struct{message: message}) when is_binary(message) do
    "#{inspect(struct)}: #{message}"
  end

  def to_iodata(message) when is_binary(message) do
    message
  end

  def to_iodata({module, tag, data}) when is_atom(module) and is_atom(tag) do
    if function_exported?(module, :format_reason, 2) do
      module.format_reason(tag, data)
    else
      format_fallback(module, tag, data)
    end
  end

  def to_iodata(other) do
    inspect(other)
  end

  @doc """
  Renders an error reason as a binary.

  Same as `to_iodata/1`, with the result collapsed into a single string.

      iex> Ark.Error.to_string({:error, :enoent})
      ":enoent"
  """
  def to_string(reason) do
    reason |> to_iodata() |> :erlang.iolist_to_binary()
  end

  @doc """
  Renders a `{module, tag, data}` error that the module does not handle itself.

  Use this as the catch-all clause of a module's `format_reason/2`, as shown in
  `Ark.Error`. It returns `inspect({module, tag, data})`. Outside of `:prod`, it
  also emits a warning suggesting the `format_reason/2` clause to add, so a
  missing formatter surfaces during development.
  """
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

      inspect({module, tag, data})
    end
  else
    def format_fallback(module, tag, data) do
      inspect({module, tag, data})
    end
  end

  @doc """
  Formats `error` with `to_string/1` and logs it at the `:error` level.

  `metadata` is passed through to `Logger.error/2`. Require the module first,
  since this is a macro.

      require Ark.Error
      Ark.Error.log_error({:error, :timeout}, request_id: request_id)
  """
  defmacro log_error(error, metadata \\ []) do
    quote do
      require Logger
      Logger.error(unquote(__MODULE__).to_string(unquote(error)), unquote(metadata))
    end
  end

  @doc """
  Formats `error` with `to_string/1` and logs it at the `:debug` level.

  Behaves like `log_error/2` but logs through `Logger.debug/2`.
  """
  defmacro debug_error(error, metadata \\ []) do
    quote do
      require Logger
      Logger.debug(unquote(__MODULE__).to_string(unquote(error)), unquote(metadata))
    end
  end
end
