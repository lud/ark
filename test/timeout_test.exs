defmodule Ark.TimeoutTest do
  use ExUnit.Case, async: true
  alias Ark.Timeout
  doctest Ark.Timeout

  defp fmt(ms, format \\ :short) do
    IO.iodata_to_binary(Timeout.format(ms, format))
  end

  describe "format/1,2 short (default)" do
    test "milliseconds only" do
      assert fmt(500) == "500ms"
      assert fmt(1) == "1ms"
    end

    test "seconds and milliseconds" do
      assert fmt(1_500) == "1s500ms"
    end

    test "minutes" do
      assert fmt(2 * 60_000) == "2m"
    end

    test "mixed units" do
      one_day_two_hours_three_minutes =
        (1 * 86_400 + 2 * 3_600 + 3 * 60) * 1_000

      assert fmt(one_day_two_hours_three_minutes) == "1d2h3m"
    end

    test "negative — short prefix" do
      assert fmt(-90_000) == "-1m30s"
    end

    test ":infinity returns \"infinity\"" do
      assert fmt(:infinity) == "infinity"
    end

    test ":hibernate returns \"infinity\"" do
      assert fmt(:hibernate) == "infinity"
    end
  end

  describe "format/2 long" do
    test "singular units" do
      assert fmt(1_000, :long) == "1 second"
      assert fmt(60_000, :long) == "1 minute"
    end

    test "plural units" do
      assert fmt(2_000, :long) == "2 seconds"
      assert fmt(3 * 60_000, :long) == "3 minutes"
    end

    test "mixed units" do
      assert fmt(3_661_000, :long) == "1 hour 1 minute 1 second"
    end

    test "milliseconds suppressed above 5 seconds" do
      assert fmt(6_500, :long) == "6 seconds"
    end

    test "milliseconds shown at or below 5 seconds" do
      assert fmt(4_500, :long) == "4 seconds 500 milliseconds"
    end

    test "negative — long prefix" do
      assert fmt(-90_000, :long) == "(negative) 1 minute 30 seconds"
    end

    test ":infinity returns \"infinity\"" do
      assert fmt(:infinity, :long) == "infinity"
    end

    test ":hibernate returns \"infinity\"" do
      assert fmt(:hibernate, :long) == "infinity"
    end
  end

  describe "until/1,2" do
    test "future datetime returns positive milliseconds" do
      now = ~U[2024-01-01 00:00:00Z]
      future = ~U[2024-01-01 00:00:01Z]
      assert Timeout.until(future, now) == 1_000
    end

    test "past datetime is clamped to 0" do
      now = ~U[2024-01-01 00:00:01Z]
      past = ~U[2024-01-01 00:00:00Z]
      assert Timeout.until(past, now) == 0
    end

    test "same datetime returns 0" do
      now = ~U[2024-01-01 00:00:00Z]
      assert Timeout.until(now, now) == 0
    end

    test "result is clamped to max 32-bit unsigned" do
      now = ~U[2024-01-01 00:00:00Z]
      far_future = ~U[2200-01-01 00:00:00Z]
      assert Timeout.until(far_future, now) == 4_294_967_295
    end

    test ":infinity is returned as-is from until/1" do
      assert Timeout.until(:infinity) == :infinity
    end

    test ":hibernate is returned as-is from until/1" do
      assert Timeout.until(:hibernate) == :hibernate
    end

    test ":infinity is returned as-is from until/2" do
      assert Timeout.until(:infinity, DateTime.utc_now()) == :infinity
    end

    test ":hibernate is returned as-is from until/2" do
      assert Timeout.until(:hibernate, DateTime.utc_now()) == :hibernate
    end
  end
end
