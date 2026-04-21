defmodule Ark.Retry do
  @moduledoc """
  Generic retry utilities.
  """

  @doc false
  def __ark__(:doc) do
    """
    This module provides base functions to retry operations.
    """
  end

  @default_max_attempts 2

  @doc """
  Executes the given function multiple times until it returns `:ok` or `{:ok,
  _}` or the `:max_attempts` option is reached. When there is no more attempts,
  returns the last return value of the function.

  ### Options

  * `:max_attempts` - the maximum number of attempts to execute the function.
    That is the maximum number of times the function is called, not _retried_.
    Giving `1` will call the function once and return its result. Defaults to
    `2`.
  * `:delay` - the delay between the first attempt and the second attempt, in
    milliseconds. Defaults to `0`. If no other option is given, the same delay
    will be used between the 2nd and 3rd call, and so on.
  * `:add` - the number of milliseconds to add to the delay between each
    attempt. Defaults to `0`.
  * `:exp` - the exponent to multiply the delay between each attempt. Defaults
    to `1`. Accepts an integer or float, but not that any float result after the
    multiplication will be truncated as we are using `Process.sleep/1`. When the
    previous delay is lower than `1`, the multiplication is done from `1`
    instead.
  * `:cap` - the maximum number of milliseconds to wait between each attempt. If
    the delay is greater than the cap, the cap will be used instead. Defaults to
    `:infinity`, which means no cap. For instance, an exponential delay will
    quickly reach very high values, so you may want to cap it to a reasonable
    time, for instance 5000 milliseconds. Modifiers are applied in option order,
    so `:cap` should usually be passed last.

  Delay modifiers are applied in the order they are given.

      delay: 1000, add: 5, exp: 2 # => 1000, 2010, 4030, ...
      delay: 1000, exp: 2, add: 5 # => 1000, 2005, 4015, ...

  ### Example

  The following function call will wait 1000, 2010, 4030 and 8070 in between
  attempts:

      retry(fn -> call_api("/get/stuff") end, max_attempts: 5, delay: 1000, add: 5, exp: 2)
  """
  def retry(fun, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)

    if max_attempts < 1 do
      raise ArgumentError, "max_attempts must be greater than 0"
    end

    delays = delay_stream(opts)
    Enum.reduce_while(delays, {fun, 1, max_attempts}, &reduce_delays/2)
  end

  defp reduce_delays(delay, {fun, attempt, max_attempts}) do
    case fun.() do
      {:ok, data} ->
        {:halt, {:ok, data}}

      :ok ->
        {:halt, :ok}

      other when attempt >= max_attempts ->
        {:halt, other}

      _other ->
        Process.sleep(delay)
        {:cont, {fun, attempt + 1, max_attempts}}
    end
  end

  def delay_stream(opts) when is_list(opts) do
    delay = Keyword.get(opts, :delay, 0)

    Stream.iterate(delay, next_delay_fun(opts))
  end

  defp next_delay_fun(opts) do
    opts =
      Enum.filter(opts, fn
        {:delay, _} -> false
        {:max_attempts, _} -> false
        {:exp, n} when is_number(n) -> true
        {:add, n} when is_number(n) -> true
        {:cap, n} when is_number(n) -> true
      end)

    fn prev_delay ->
      Enum.reduce(opts, prev_delay, fn opt, prev_delay -> next_delay(prev_delay, opt) end)
    end
  end

  defp next_delay(prev_delay, {:exp, n}) when prev_delay < 1 do
    next_delay(1, {:exp, n})
  end

  defp next_delay(prev_delay, {:exp, n}) do
    trunc(prev_delay * n)
  end

  defp next_delay(prev_delay, {:add, n}) do
    prev_delay + n
  end

  defp next_delay(prev_delay, {:cap, n}) do
    min(prev_delay, n)
  end
end
