defmodule Ark.Paginator do
  @doc false
  def __ark__(:doc) do
    """
    This module provides a helper to build streams from paginated sources.

    A user-supplied callback is called with an initial state and is expected to
    return the items for the current page along with the next state, until it
    signals that pagination is over.

    ```elixir
    pages = %{1 => [1, 2, 3], 2 => [4, 5, 6]}

    {:ok, stream} =
      Ark.Paginator.stream(1, fn page ->
        case Map.get(pages, page, []) do
          [] -> {:halt, []}
          items -> {:cont, items, page + 1}
        end
      end)

    Enum.to_list(stream)
    # => [1, 2, 3, 4, 5, 6]
    ```
    """
  end

  @type state :: term

  @type paginator_fun :: (state ->
                            {:cont, Enumerable.t(), state}
                            | {:halt, Enumerable.t()}
                            | {:error, term})

  @doc """
  Accepts an initial state and a pagination callback and immediately calls the
  callback with the initial state, expecting a result tuple.

  If the callback returns `{:cont, items, new_state}`, then this function
  returns `{:ok, stream}`, otherwise it returns the same `{:error, reason}`
  tuple as the callback did.

  The callback is intended to be a stream generator, so it can return one of the
  following:

  - `{:cont, items, new_state}`: Returns the items to be part of the stream, and
    a new state. The items can be a list, or a stream.
  - `{:halt, items}`: Returns the last items or stream and stops the pagination.
    The callback will not be called again.
  - `{:error, reason}`: Returns an error and stops the pagination. The stream
    will emit an error.


  ### Example

      iex> pages = %{1 => [1, 2, 3], 2 => [98, 99, 100]}
      iex> {:ok, stream} =
      iex>   Paginator.stream(1, fn
      iex>     page ->
      iex>       case Map.get(pages, page, []) do
      iex>         [] -> {:halt, []}
      iex>         items -> {:cont, items, page + 1}
      iex>       end
      iex>   end)
      iex> Enum.to_list(stream)
      [1, 2, 3, 98, 99, 100]
  """
  @spec stream(state, paginator_fun()) :: {:ok, Enumerable.t()} | {:error, term}
  def stream(initial_state, callback) do
    # Call the first page to know if there is an error, and stream the next
    # pages.
    case callback.(initial_state) do
      {:cont, items, new_state} -> {:ok, do_stream(new_state, callback, items)}
      {:halt, items} -> {:ok, items}
      {:error, _} = err -> err
    end
  end

  defp do_stream(user_state, callback, first_page_items) do
    # Supporting {:halt, last_items} in user code
    #
    # If the user know they reached the last page, they will want to return a
    # :halt tuple as there is no need to call the next page that will be empty
    # or 404.
    #
    # But the last page may contain items to return ; we need to be able to
    # return that :halt tuple.
    #
    # On the other hand, Stream.resource/3 does not support this, and only
    # supports {:halt, acc} tuples, without items.
    #
    # Hence the :halted state, meaning "user code halted". The resource stream
    # continues and will be halted on the next call.
    next_pages_stream =
      Stream.resource(
        fn -> {:ongoing, user_state} end,
        fn
          {:ongoing, user_state} ->
            case callback.(user_state) do
              {:cont, next_items, new_user_state} ->
                {next_items, {:ongoing, new_user_state}}

              {:halt, next_items} ->
                {next_items, :halted}

              {:error, reason} ->
                raise "error in paginator callback: #{inspect(reason)}"
            end

          :halted ->
            {:halt, :halted}
        end,
        # after_fun arg can be {:ongoing,_} state if there is an error/exception
        fn
          :halted -> :ok
          {:ongoing, _} -> :ok
        end
      )

    Stream.concat(first_page_items, next_pages_stream)
  end
end
