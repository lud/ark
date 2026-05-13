defmodule Ark.Timeout do
  @doc false
  def __ark__(:doc) do
    """
    Helpers to work with numerical timeout values
    """
  end

  @doc """
  Returns the milliseconds until `datetime`, clamped to `[0, 4_294_967_295]`.

  Also accepts `:infinity` or `:hibernate`, returning the atom as-is.

  An optional `now` argument overrides the current time (defaults to
  `DateTime.utc_now/0`).
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
  Formats a millisecond duration as a human-readable string.

  Also accepts `:infinity` or `:hibernate`, returning `"infinity"` for both.

  Accepts an optional `format` argument:
  - `:short` (default) — compact form, e.g. `"1d2h3m"`
  - `:long` — verbose form, e.g. `"1 day 2 hours 3 minutes"`

  Negative values produce a `"-"` prefix in short format and a `"(negative) "`
  prefix in long format.
  """
  @spec format(non_neg_integer() | :infinity | :hibernate) :: iodata()
  def format(total_ms) do
    format(total_ms, :short)
  end

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
