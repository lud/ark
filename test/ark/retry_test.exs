defmodule Ark.RetryTest do
  use ExUnit.Case, async: true

  alias Ark.Retry

  use ExUnit.Case, async: false

  defp mut_val(initial_value) do
    ref = make_ref()
    Process.put(ref, initial_value)

    getter = fn -> Process.get(ref) end
    setter = fn value -> Process.put(ref, value) end
    {getter, setter}
  end

  test "should retry the given callback" do
    f = fn ->
      send(self(), :called)
      {:error, :nope}
    end

    assert {:error, :nope} = Retry.retry(f, max_attempts: 5)

    for _ <- 1..5 do
      assert_received(:called)
    end

    refute_received :called
  end

  test "the default attempt count is 2 (retry once)" do
    f = fn ->
      send(self(), :called)
      {:error, :nope}
    end

    assert {:error, :nope} = Retry.retry(f)

    for _ <- 1..2 do
      assert_received(:called)
    end

    refute_received :called
  end

  test "the default delay is zero" do
    f = fn ->
      send(self(), :called)
      {:error, :nope}
    end

    {time, {:error, :nope}} =
      :timer.tc(
        fn ->
          assert {:error, :nope} = Retry.retry(f)
        end,
        :millisecond
      )

    assert_in_delta 0, time, 10

    for _ <- 1..2 do
      assert_received(:called)
    end

    refute_received :called
  end

  test "the retry stops as soon as an ok reply is returned" do
    {get_flag, set_flag} = mut_val(false)

    f = fn ->
      reply =
        case get_flag.() do
          true -> {:ok, :hello}
          _ -> {:error, :call_me_again}
        end

      set_flag.(true)

      send(self(), :called)
      reply
    end

    assert {:ok, _} = Retry.retry(f, max_attempts: 1000)

    for _ <- 1..2 do
      assert_received(:called)
    end

    refute_received :called
  end

  test "an :ok response is valid" do
    {get_flag, set_flag} = mut_val(false)

    f = fn ->
      reply =
        case get_flag.() do
          true -> :ok
          _ -> {:error, :call_me_again}
        end

      set_flag.(true)

      send(self(), :called)
      reply
    end

    assert :ok = Retry.retry(f, max_attempts: 1000)

    for _ <- 1..2 do
      assert_received(:called)
    end

    refute_received :called
  end

  test "the delay can be raised by addition" do
    delayer = Retry.delay_stream(delay: 1000, add: 1000)

    assert [1000, 2000, 3000] = Enum.take(delayer, 3)
  end

  test "the delay can be raised by multiplication" do
    delayer = Retry.delay_stream(delay: 1000, exp: 2)

    assert [1000, 2000, 4000, 8000] = Enum.take(delayer, 4)
  end

  test "the delay can be raised by float multiplication" do
    delayer = Retry.delay_stream(delay: 1000, exp: 1.5)

    assert [1000, 1500, 2250, 3375] = Enum.take(delayer, 4)
  end

  test "the delay can be capped" do
    delayer = Retry.delay_stream(delay: 1000, exp: 2, cap: 5000)

    assert [1000, 2000, 4000, 5000, 5000, 5000] = Enum.take(delayer, 6)
  end

  test "delay modifiers are applied in order: add then exp" do
    delayer = Retry.delay_stream(delay: 1000, add: 5, exp: 2)

    assert [1000, 2010, 4030] = Enum.take(delayer, 3)
  end

  test "delay modifiers are applied in order: exp then add" do
    delayer = Retry.delay_stream(delay: 1000, exp: 2, add: 5)

    assert [1000, 2005, 4015] = Enum.take(delayer, 3)
  end

  test "delay defaults to zero when omitted" do
    delayer = Retry.delay_stream([])

    assert [0, 0, 0] = Enum.take(delayer, 3)
  end

  test "when delay is omitted modifiers are applied in order: add then exp" do
    delayer = Retry.delay_stream(add: 5, exp: 2)

    assert [0, 10, 30] = Enum.take(delayer, 3)
  end

  test "when delay is omitted modifiers are applied in order: exp then add" do
    delayer = Retry.delay_stream(exp: 2, add: 5)

    assert [0, 7, 19] = Enum.take(delayer, 3)
  end

  test "when delay is omitted (defaults to 0) exponent treats it as 1" do
    delayer = Retry.delay_stream(exp: 2)

    assert [0, 2, 4] = Enum.take(delayer, 3)
  end

  test "max_attempts must be greater than zero" do
    assert_raise ArgumentError, ~r/greater than 0/, fn ->
      Retry.retry(fn -> :ok end, max_attempts: 0)
    end
  end
end
