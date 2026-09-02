defmodule Ark.Error do
  @moduledoc ~S"""
  Turns error reasons into human-readable text.

  Elixir code commonly returns errors as the `reason` in an `{:error, reason}`
  tuple, where `reason` can be a string, an exception, a changeset, or any term.
  `Ark.Error` renders any of these into a message you can log or show, without
  having to match on the shape first.

      iex> Ark.Error.to_string({:error, "database is down"})
      "database is down"

  `to_iodata/2` and `to_string/2` accept, among others:

    * a binary message, returned as-is
    * an exception struct, rendered with `Exception.message/1`
    * an `{exception, stacktrace}` pair, rendered as a banner
    * a nested `{:error, reason}` or `{:shutdown, reason}` tuple
    * an `Ecto.Changeset` or `Ecto.InvalidChangesetError`, when Ecto is loaded
    * any other term, rendered with `inspect/1`

  ### Audiences

  Both functions take an audience, either `:private` (the default) or
  `:public`. The private rendering is meant for logs and developers, and falls
  back to `inspect/1` for any term. The public rendering is meant for messages
  shown to end users:

    * an `{exception, stacktrace}` pair is rendered with `Exception.message/1`
      instead of the banner
    * a `{tag, reason}` tuple with an atom tag is rendered as `"(tag) "`
      followed by the rendering of `reason`
    * atoms and numbers are rendered with `inspect/1`
    * any other term produces `"unknown error"` while the full term is logged
      at the `:error` level

      iex> Ark.Error.to_string({:error, %{secret: "shh"}}, :private)
      "%{secret: \"shh\"}"

      iex> Ark.Error.to_string({:error, :timeout}, :public)
      ":timeout"

      iex> Ark.Error.to_string({:error, %{secret: "shh"}}, :public)
      "unknown error"

      iex> Ark.Error.to_string({:error, {:enoent, "/etc/hosts"}}, :public)
      "(enoent) /etc/hosts"

  ### Custom error formatting

  An error can also be a `{module, tag, data}` triple, which lets a module
  render its own errors. When `module` exports `format_reason/3`, it is called
  with `tag`, `data` and the audience to produce the message. A
  `format_reason/2` callback without the audience is also supported:

      defmodule MyApp.Upload do
        @spec format_reason(term, term, Ark.Error.audience()) :: iodata
        def format_reason(:too_large, size, _audience) do
          "file is too large: #{size} bytes"
        end

        def format_reason(other, data, audience) do
          Ark.Error.format_fallback(__MODULE__, other, data, audience)
        end
      end

      Ark.Error.to_string({MyApp.Upload, :too_large, 5_000_000})
      # => "file is too large: 5000000 bytes"

  `format_fallback/4` renders any tag the module does not handle, so a single
  catch-all clause covers every remaining case.

  ### Logging helpers

  `log_error/2` and `debug_error/2` format a reason for the `:private`
  audience and send it to `Logger` at the `:error` and `:debug` levels:

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
  require Logger

  @type audience :: :private | :public

  @doc """
  Renders an error reason as `t:iodata/0`.

  Accepts the shapes listed in `Ark.Error`. Returning iodata avoids building
  intermediate strings, which is convenient when the result goes straight to
  `Logger` or `IO`.

      iex> IO.iodata_to_binary(Ark.Error.to_iodata({:shutdown, "node left"}))
      "(shutdown) node left"
  """
  @spec to_iodata(any, audience) :: iodata()
  def to_iodata(reason, audience \\ :private)

  def to_iodata({:error, e}, audience) do
    to_iodata(e, audience)
  end

  def to_iodata({:shutdown, e}, audience) do
    ["(shutdown) ", to_iodata(e, audience)]
  end

  case Code.ensure_loaded(Ecto.Changeset) do
    {:module, _} ->
      def to_iodata(
            %Ecto.InvalidChangesetError{changeset: changeset, action: action},
            audience
          ) do
        [
          "could not perform changeset action ",
          inspect(action),
          " ",
          to_iodata(changeset, audience)
        ]
      end

      def to_iodata(%Ecto.Changeset{} = changeset, _audience) do
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

  def to_iodata({%{__exception__: true} = e, stack}, :private) when is_list(stack) do
    Exception.format_banner(:error, e, stack)
  end

  def to_iodata({%{__exception__: true} = e, stack}, :public) when is_list(stack) do
    Exception.message(e)
  end

  def to_iodata(%{__exception__: true} = e, _audience) do
    Exception.message(e)
  end

  def to_iodata(%struct{message: message}, _audience) when is_binary(message) do
    "#{inspect(struct)}: #{message}"
  end

  def to_iodata(message, _audience) when is_binary(message) do
    message
  end

  def to_iodata({module, tag, data} = reason, audience)
      when is_atom(module) and is_atom(tag) do
    cond do
      function_exported?(module, :format_reason, 3) ->
        module.format_reason(tag, data, audience)

      function_exported?(module, :format_reason, 2) ->
        module.format_reason(tag, data)

      true ->
        fallback(reason, audience)
    end
  end

  def to_iodata({tag, sub_reason}, :public) when is_atom(tag) do
    ["(", Atom.to_string(tag), ") ", to_iodata(sub_reason, :public)]
  end

  def to_iodata(other, audience) do
    fallback(other, audience)
  end

  defp fallback(reason, :private) do
    inspect(reason)
  end

  defp fallback(reason, :public) when is_atom(reason) or is_number(reason) do
    inspect(reason)
  end

  defp fallback(reason, :public) do
    Logger.error(["could not generate a public error message for ", inspect(reason)])
    "unknown error"
  end

  @doc """
  Renders an error reason as a binary.

  Same as `to_iodata/2`, with the result collapsed into a single string.

      iex> Ark.Error.to_string({:error, :enoent})
      ":enoent"
  """
  @spec to_string(any, audience) :: binary
  def to_string(reason, audience \\ :private) do
    reason |> to_iodata(audience) |> :erlang.iolist_to_binary()
  end

  @doc """
  Renders a `{module, tag, data}` error that the module does not handle itself.

  Use this as the catch-all clause of a module's `format_reason/3`, as shown in
  `Ark.Error`. The triple is rendered like any other term for the given
  audience.
  """
  @spec format_fallback(module, atom, term, audience) :: binary
  def format_fallback(module, tag, data, audience \\ :private) do
    fallback({module, tag, data}, audience)
  end

  @doc """
  Formats `error` with `to_string/2` for the `:private` audience and logs it at
  the `:error` level.

  `metadata` is passed through to `Logger.error/2`. Require the module first,
  since this is a macro.

      require Ark.Error
      Ark.Error.log_error({:error, :timeout}, request_id: request_id)
  """
  defmacro log_error(error, metadata \\ []) do
    quote do
      require Logger

      Logger.error(
        unquote(__MODULE__).to_string(unquote(error), :private),
        unquote(metadata)
      )
    end
  end

  @doc """
  Formats `error` with `to_string/2` for the `:private` audience and logs it at
  the `:debug` level.

  Behaves like `log_error/2` but logs through `Logger.debug/2`.
  """
  defmacro debug_error(error, metadata \\ []) do
    quote do
      require Logger

      Logger.debug(
        unquote(__MODULE__).to_string(unquote(error), :private),
        unquote(metadata)
      )
    end
  end
end
