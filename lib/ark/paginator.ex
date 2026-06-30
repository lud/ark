defmodule Ark.Paginator do
  @moduledoc """
  Builds a `Stream` from a paginated source.

  Many APIs return results one page at a time, with a token or number pointing
  to the next page. `Ark.Paginator` turns that pattern into a single lazy
  stream: you supply a callback that fetches one page and reports how to
  continue, and the paginator calls it as the stream is consumed.

      iex> pages = %{1 => [1, 2, 3], 2 => [4, 5, 6]}
      iex> {:ok, stream} =
      ...>   Ark.Paginator.stream(1, fn page ->
      ...>     case Map.get(pages, page, []) do
      ...>       [] -> {:halt, []}
      ...>       items -> {:cont, items, page + 1}
      ...>     end
      ...>   end)
      iex> Enum.to_list(stream)
      [1, 2, 3, 4, 5, 6]

  See `stream/2` for the callback contract, the return shapes, and how errors
  are surfaced.
  """

  defmodule CallbackError do
    @moduledoc """
    Raised when a paginator callback returns `{:error, reason}` after the first
    page, where `reason` is not itself an exception.

    The `reason` is kept in the `:reason` field. See `Ark.Paginator.stream/2`
    for when this is raised instead of returned.
    """
    defexception [:reason]

    @impl true
    def message(%{reason: reason}) do
      "error in paginator callback: #{inspect(reason)}"
    end
  end

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
  callback with the initial state.

  The callback receives the current state and must return one of:

  - `{:cont, items, new_state}`: Yields items into the stream and continues
    pagination with `new_state`. Items can be any `Enumerable` (list or stream).
  - `{:halt, items}`: Yields a final set of items and stops. The callback will
    not be called again. Useful when the current response already signals it
    was the last page, so no extra request is needed.
  - `{:error, reason}`: Stops pagination with an error.

  ## Return shapes

  - `{:ok, stream}` when the first call returns `{:cont, items, new_state}`.
    The stream lazily concatenates the items from this and all following pages.
  - `{:ok, items}` when the first call returns `{:halt, items}`. No stream is
    built; pagination ends immediately and the items are returned as-is.
  - `{:error, reason}` when the first call returns `{:error, reason}`. The
    callback's error tuple is returned unchanged.

  ## Error handling

  Errors are surfaced differently depending on when they happen:

  - On the **first call**, `{:error, reason}` is returned as a tagged tuple so
    that initial failures (auth, network, bad config) can be handled without
    exception machinery.
  - On **subsequent calls**, the error is raised, since a stream has no way to
    surface an error tuple to its consumer:
      - If `reason` is itself an exception struct, it is raised as-is.
      - Otherwise, a `Ark.Paginator.CallbackError` is raised with `reason` set on the
        struct.

  ## Example

      iex> pages = %{1 => [1, 2, 3], 2 => [98, 99, 100]}
      iex> {:ok, stream} =
      ...>   Ark.Paginator.stream(1, fn page ->
      ...>     case Map.get(pages, page, []) do
      ...>       [] -> {:halt, []}
      ...>       items -> {:cont, items, page + 1}
      ...>     end
      ...>   end)
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

              {:error, %_{__exception__: true} = exception} ->
                raise exception

              {:error, reason} ->
                raise __MODULE__.CallbackError, reason: reason
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
