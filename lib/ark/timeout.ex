defmodule Ark.Timeout do
  @moduledoc """
  Helpers for working with millisecond timeout values.

  Timeouts in OTP are a number of milliseconds, or one of the atoms `:infinity`
  and `:hibernate`. This module computes a timeout from a target `DateTime` and
  renders a duration as readable text, passing those atoms through untouched so
  the helpers fit anywhere a timeout is expected.

      iex> Ark.Timeout.until(:infinity)
      :infinity
      iex> IO.iodata_to_binary(Ark.Timeout.format(1_500))
      "1s500ms"
  """

  @doc false
  def __ark__(:doc) do
    """
    Helpers to work with numerical timeout values
    """
  end

  @doc """
  Returns the number of milliseconds from now until `date_time`, clamped to `[0,
  4_294_967_295]`.

  Also accepts `:infinity` or `:hibernate`, returning the atom unchanged, so the
  result can be given to a `receive` or `GenServer` timeout.

      iex> Ark.Timeout.until(:infinity)
      :infinity

  To measure against a fixed reference time, use `until/2`.
  """
  @spec until(DateTime.t() | :infinity | :hibernate) ::
          non_neg_integer() | :infinity | :hibernate
  def until(date_time)

  def until(inf) when inf in [:infinity, :hibernate] do
    inf
  end

  def until(%DateTime{} = datetime) do
    until(datetime, DateTime.utc_now())
  end

  @doc """
  Returns the number of milliseconds from `now` until `datetime`, clamped to
  `[0, 4_294_967_295]`.

  Like `until/1`, but takes the reference time explicitly instead of reading
  `DateTime.utc_now/0`, which makes it deterministic to test. `:infinity` and
  `:hibernate` are returned unchanged.

      iex> now = ~U[2024-01-01 00:00:00Z]
      iex> later = ~U[2024-01-01 00:00:10Z]
      iex> Ark.Timeout.until(later, now)
      10000
  """
  @spec until(DateTime.t() | :infinity | :hibernate, DateTime.t()) ::
          non_neg_integer() | :infinity | :hibernate
  def until(datetime, _now) when datetime in [:infinity, :hibernate] do
    datetime
  end

  def until(%DateTime{} = datetime, %DateTime{} = now) do
    datetime
    |> DateTime.diff(now, :millisecond)
    |> max(0)
    |> min(4_294_967_295)
  end

  @doc """
  Formats a millisecond duration as a compact human-readable string.

  Uses the `:short` format, for example `"1d2h3m"`. Call `format/2` to choose
  the format. `:infinity` and `:hibernate` both render as `"infinity"`. The
  result is `t:iodata/0`.

      iex> IO.iodata_to_binary(Ark.Timeout.format(1_500))
      "1s500ms"
  """
  @spec format(non_neg_integer() | :infinity | :hibernate) :: iodata()
  def format(total_ms) do
    format(total_ms, :short)
  end

  @doc """
  Formats a millisecond duration as a human-readable string in the chosen
  format.

  The `format` argument selects the rendering:

    * `:short` - compact form, for example `"1d2h3m"`
    * `:long` - verbose form, for example `"1 day 2 hours 3 minutes"`

  `:infinity` and `:hibernate` both render as `"infinity"`. A negative duration
  is prefixed with `"-"` in the short format and `"(negative) "` in the long
  format. The result is `t:iodata/0`.

      iex> IO.iodata_to_binary(Ark.Timeout.format(90_000, :long))
      "1 minute 30 seconds"
  """
  @spec format(non_neg_integer() | :infinity | :hibernate, :short | :long) :: iodata()
  def format(total_ms, _format) when total_ms in [:infinity, :hibernate] do
    "infinity"
  end

  def format(total_ms, format) when total_ms < 0 do
    case format do
      :short -> ["-" | format_abs(-total_ms, :short)]
      :long -> ["(negative) " | format_abs(-total_ms, :long)]
    end
  end

  def format(total_ms, format) do
    format_abs(total_ms, format)
  end

  defp format_abs(total_ms, :short) do
    total_seconds = div(total_ms, 1_000)
    ms = rem(total_ms, 1_000)
    {d, {h, m, s}} = :calendar.seconds_to_daystime(total_seconds)
    format_short([d, h, m, s, ms], ["d", "h", "m", "s", "ms"])
  end

  defp format_abs(total_ms, :long) do
    total_seconds = div(total_ms, 1_000)

    ms =
      if total_seconds > 5 do
        0
      else
        rem(total_ms, 1_000)
      end

    {d, {h, m, s}} = :calendar.seconds_to_daystime(total_seconds)
    format_long([d, h, m, s, ms], ["day", "hour", "minute", "second", "millisecond"], "")
  end

  defp format_short([0 | vs], [_ | ns]) do
    format_short(vs, ns)
  end

  defp format_short([v | vs], [name | ns]) do
    [[Integer.to_string(v), name] | format_short(vs, ns)]
  end

  defp format_short([], _) do
    []
  end

  defp format_long([0 | vs], [_ | ns], space) do
    format_long(vs, ns, space)
  end

  defp format_long([v | vs], [name | ns], space) do
    figure =
      case v do
        1 -> ["1 ", name]
        _ -> [Integer.to_string(v), " ", name, "s"]
      end

    [space, figure | format_long(vs, ns, " ")]
  end

  defp format_long([], _, _) do
    []
  end
end
