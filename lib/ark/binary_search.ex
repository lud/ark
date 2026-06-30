defmodule Ark.BinarySearch do
  @moduledoc """
  Finds an integer by repeatedly probing candidates with a comparison callback.

  The search never holds the candidate values itself. It calls a function you
  provide with a guess, and that function reports how the guess compares to the
  integer being looked for. This suits finding a boundary in a large or
  unbounded space, such as the largest page size an API still accepts, where you
  can test a value but cannot list every possibility.

  The callback receives an integer and returns one of:

    * `:eq` - the guess is the integer being searched for
    * `:lt` - the guess is lower than the searched integer
    * `:gt` - the guess is greater than the searched integer

  ### Examples

  Searching across the whole integer range with `search/1`:

      iex> ask = fn
      ...>   42 -> :eq
      ...>   n when n < 42 -> :lt
      ...>   n when n > 42 -> :gt
      ...> end
      iex> Ark.BinarySearch.search(ask)
      42

  Searching within known bounds with `search/3`:

      iex> ask = fn
      ...>   7 -> :eq
      ...>   n when n < 7 -> :lt
      ...>   n when n > 7 -> :gt
      ...> end
      iex> Ark.BinarySearch.search(ask, 0, 100)
      7
  """

  @doc false
  def __ark__(:doc) do
    """
    This module provides an integer binary search driven by a comparison
    callback.
    """
  end

  @doc """
  Searches for the integer over the whole integer range.

  Starts at `0` and expands the search bounds outward, in either direction,
  until they bracket the target, then narrows in. Use this when you have no
  prior idea of where the integer lies, including when it may be negative.

  See `Ark.BinarySearch` for the contract the `ask` callback must follow.

      iex> ask = fn
      ...>   -5 -> :eq
      ...>   n when n < -5 -> :lt
      ...>   n when n > -5 -> :gt
      ...> end
      iex> Ark.BinarySearch.search(ask)
      -5
  """
  def search(ask) do
    case ask.(0) do
      :eq -> 0
      :gt -> search(ask, search_min(ask, -1), 0)
      :lt -> search(ask, 0, search_max(ask, 1))
    end
  catch
    {:found, n} -> n
  end

  @doc """
  Searches for the integer within the inclusive range `min..max`.

  Use this when you already know bounds that contain the integer. It probes the
  middle of the current range and halves the range on each step.

  See `Ark.BinarySearch` for the contract the `ask` callback must follow.

      iex> ask = fn
      ...>   30 -> :eq
      ...>   n when n < 30 -> :lt
      ...>   n when n > 30 -> :gt
      ...> end
      iex> Ark.BinarySearch.search(ask, 0, 64)
      30
  """
  def search(ask, min, max) do
    n = div(min + max, 2)

    case ask.(n) do
      # n is lower than the answer
      :lt -> search(ask, n + 1, max)
      # n is greater than the answer
      :gt -> search(ask, min, n - 1)
      :eq -> n
    end
  end

  defp search_min(ask, n) do
    # :lt means n is lower than the answer
    # :get means n is greater than the answer
    case ask.(n) do
      :gt -> search_min(ask, n * 2)
      :lt -> n
      :eq -> throw({:found, n})
    end
  end

  defp search_max(ask, n) do
    # :lt means n is lower than the answer
    # :get means n is greater than the answer
    case ask.(n) do
      :lt -> search_max(ask, n * 2)
      :gt -> n
      :eq -> throw({:found, n})
    end
  end
end
