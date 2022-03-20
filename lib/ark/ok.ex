defmodule Ark.Ok do
  defmodule UnwrapError do
    defexception [:value]

    def message(%{value: value}) do
      "Could not unwrap value: #{inspect(value)}"
    end
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
    raise UnwrapError, value: other
  end

  @doc """
  Unwrapping ok, raising custom exceptions.

  Much like `uok!/1` but if an `:error` 2-tuple contains any exception as the
  second element, that exception will be raised.

  Other values will lead to a generic `Ark.Ok.UnwrapError` exception to be
  reaised.
  """
  defmacro xok!(value) do
    quote do
      case unquote(value) do
        :ok -> :ok
        {:ok, value} -> value
        {:error, %{__exception__: true} = e} -> raise e
        other -> raise UnwrapError, value: other
      end
    end
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

  @doc """
  Mapping while ok.  Takes an enumerable and applies the given callback to all
  values of the enumerable as long as the callback returns `{:ok,
  mapped_value}`.

  Stops when the callback returns `{:error, term}` and returns that tuple.

  Returns `{:error, {:bad_return, {callback, [item]}, returned_value}}` if the
  callback does not return a result tuple.

  Returns `{:ok, mapped_values}` or `{:error, term}`
  """
  @spec map_ok(Enumerable.t(), (term -> {:ok, term} | {:error, term})) ::
          {:ok, list} | {:error, term}
  def map_ok(enum, f) when is_function(f, 1) do
    Enum.reduce_while(enum, [], fn item, acc ->
      case f.(item) do
        {:ok, result} -> {:cont, [result | acc]}
        {:error, _} = err -> {:halt, err}
        other -> {:halt, {:error, {:bad_return, {f, [item]}, other}}}
      end
    end)
    |> case do
      {:error, _} = err -> err
      acc -> {:ok, :lists.reverse(acc)}
    end
  end

  @doc """
  Reducing while ok. Takes an enumerable, an initial value for the accumulator
  and a reducer function. Calls the reducer for each value in the enumerable as
  long as the reducer returns `{:ok, new_acc}`.

  Stops when the reducer returns `{:error, term}` and returns that tuple.

  Returns `{:error, {:bad_return, {reducer, [item, acc]}, returned_value}}` if
  the reducer does not return a result tuple.
  """
  @spec reduce_ok(Enumerable.t(), term, (term, term -> {:ok, term} | {:error, term})) ::
          {:ok, term}
          | {:error, term}
  def reduce_ok(enum, initial, f) when is_function(f, 2) do
    Enum.reduce_while(enum, initial, fn item, acc ->
      case f.(item, acc) do
        {:ok, new_acc} -> {:cont, new_acc}
        {:error, _} = err -> {:halt, err}
        other -> {:halt, {:error, {:bad_return, {f, [item, acc]}, other}}}
      end
    end)
    |> case do
      {:error, _} = err -> err
      acc -> {:ok, acc}
    end
  end
end
