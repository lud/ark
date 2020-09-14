defmodule Ark.Ok do
  defmodule UnwrapError do
    defexception [:message]
  end

  @doc false
  def __ark__(:doc) do
    """
    This module provides function to work with ok/error tuples.
    """
  end

  @doc """
  Wrapping ok.

  Converts a value to an `:ok` tuple, except when the value is:
  - the single atom `:ok` or an `:ok` tuple
  - the single atom `:error` or an `:error` tuple
  """
  def ok(value)

  def ok(:ok),
    do: :ok

  def ok(tuple) when elem(tuple, 0) in [:ok, :error],
    do: tuple

  def ok(:error),
    do: :error

  def ok(val),
    do: {:ok, val}

  @doc """
  `wok` is an alias of wrapping function `:ok`.
  """
  def wok(value),
    do: ok(value)

  @doc """
  Unwrapping ok.

  Unwraps an `{:ok, val}` tuple, giving only the value, returning anything else
  as-is. Does not unwrap `{:error, ...}` tuples.

  This function should not be used as it leads to ambiguous code where errors
  are still wrapped in tuples but values are "naked". A case pattern matching on
  that type would be very unusual in Elixir/Erlang. Match on the original value
  or use `uok!/1`.
  """
  @deprecated "Match on the values or use the raising version uok!/1"
  def uok(value)

  def uok({:ok, val}),
    do: val

  def uok(other),
    do: other

  @doc """
  Unwrapping ok with raise.

  Unwraps an `{:ok, val}` tuple, giving only the value, or returns the single
  `:ok` atom as-is. Raises with any other value.
  """
  def uok!(value)

  def uok!(:ok),
    do: :ok

  def uok!({:ok, val}),
    do: val

  def uok!(other) do
    raise UnwrapError, message: "Could not unwrap value: #{inspect(other)}"
  end

  @doc """
  Questionning ok.

  Returns `true` if the value is an `{:ok, val}` tuple or the single
  atom `:ok`.

  Returns `false` otherwise.
  """
  def ok?(value)

  def ok?(:ok),
    do: true

  def ok?({:ok, _}),
    do: true

  def ok?(_),
    do: false
end
