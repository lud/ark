defmodule Ark.DripTest2 do
  use ExUnit.Case, async: true
  alias Ark.Drip

  defp test_bucket(max_drips, range_ms, start_time) do
    assert {:ok, bucket} =
             Drip.new_bucket(
               max_drips: max_drips,
               range_ms: range_ms,
               start_time: start_time
             )

    assert %Drip{
             ranges: {low_range, high_range},
             stage: 1,
             usage: {0, 0, 0},
             allowance: ^max_drips,
             max_drips: ^max_drips
           } = bucket

    assert range_ms == low_range * 2 + high_range
    expected_end = start_time + high_range

    assert expected_end == bucket.slot_end

    bucket
  end

  test "threes, consume early" do
    b = test_bucket(3, 1000, 0)

    # we can immediately enqueue the full capacity at time zero

    assert {:ok, b} = Drip.drop(b, 0)
    assert {:ok, b} = Drip.drop(b, 0)
    assert {:ok, b} = Drip.drop(b, 0)

    assert %{allowance: 0} = b

    # now that all drips have been consumed, further calls are rejected

    assert {:reject, b} = Drip.drop(b, 0)

    # we are moving time to slot two. calls should still be rejected

    assert {:reject, b} = Drip.drop(b, 400)

    # same with slot three

    assert {:reject, b} = Drip.drop(b, 999)

    # now our bucket should be full and we can drop anew

    assert {:ok, b} = Drip.drop(b, 1000)
    assert {:ok, b} = Drip.drop(b, 1000)
    assert {:ok, b} = Drip.drop(b, 1000)
  end

  test "threes, consume late" do
    b = test_bucket(3, 1000, 0)

    # we can immediately enqueue the full capacity at time zero

    assert {:ok, b} = Drip.drop(b, 997)
    assert {:ok, b} = Drip.drop(b, 998)
    assert {:ok, b} = Drip.drop(b, 999)

    assert %{allowance: 0} = b

    # since we consumed 3 on the third third of the time period, we should only
    # be able to consume in the third third of the second period

    assert {:reject, b} = Drip.drop(b, 1000 + 000)
    assert {:reject, b} = Drip.drop(b, 1000 + 100)
    assert {:reject, b} = Drip.drop(b, 1000 + 200)
    assert {:reject, b} = Drip.drop(b, 1000 + 300)
    assert {:reject, b} = Drip.drop(b, 1000 + 400)
    assert {:reject, b} = Drip.drop(b, 1000 + 500)
    assert {:reject, b} = Drip.drop(b, 1000 + 600)

    # and we can consume them all

    assert {:ok, b} = Drip.drop(b, 1000 + 700)
    assert {:ok, b} = Drip.drop(b, 1000 + 700)
    assert {:ok, b} = Drip.drop(b, 1000 + 700)
  end

  test "threes, consume irregular" do
    b = test_bucket(3, 1000, 0)

    # we consume one in the 1/3, and two in the 2/3

    assert {:ok, b} = Drip.drop(b, 0)
    assert {:ok, b} = Drip.drop(b, 400)
    assert {:ok, b} = Drip.drop(b, 400)

    # we cannot consume more in the 2/3 or in 3/3

    assert {:reject, b} = Drip.drop(b, 400)
    assert {:reject, b} = Drip.drop(b, 999)

    # in the second period we can consume one from the 1/3 and 2 in the 2/3

    assert {:ok, branch1} = Drip.drop(b, 1000 + 0)
    assert {:reject, branch1} = Drip.drop(branch1, 1000 + 0)
    assert {:ok, branch1} = Drip.drop(b, 1000 + 400)
    assert {:ok, branch1} = Drip.drop(b, 1000 + 400)

    # but if we don't, we can also consume 3 if we wait for the 3/3

    assert {:ok, _} = Drip.drop(b, 1000 + 670)
  end

  test "consume in loop and max time" do
    # - we will create a bucket that can drop 20 in 100.
    # - we will drop 3000 drips
    # - whenever we encounter an :error (rejection), we warp 10ms in the
    #   future.
    # - this should take 15 seconds, so 15,000 ms. We will assert that we were
    #   able to do so in less than 15,000 ms

    # bucket config
    max_drips = 20
    range_ms = 100
    start_time = 0

    # test config
    iterations = 30000
    warp_time = 10
    maximum_expected_time = iterations / max_drips * range_ms

    IO.puts(
      "maximum_expected_time = (#{iterations} / #{max_drips}) * #{range_ms} = #{round(iterations / max_drips)} * #{range_ms} = #{round(maximum_expected_time)}"
    )

    bucket = test_bucket(max_drips, range_ms, start_time)
    accin = {bucket, start_time}

    # a function that will increment time until the drop is accepted, and
    # returns the new bucket and the new time

    loop = fn f, bucket, now ->
      case Drip.drop(bucket, now) do
        {:reject, bucket} ->
          new_now = now + warp_time
          f.(f, bucket, new_now)

        {:ok, bucket} ->
          {bucket, now}
      end
    end

    {b, end_time} =
      Enum.reduce(1..iterations, {bucket, 0}, fn n, {bucket, now} ->
        {bucket, now} = loop.(loop, bucket, now)
      end)

    assert end_time < maximum_expected_time
    end_time |> IO.inspect(label: "end_time")
    assert iterations == b.count
  end

  test "large rotate resets"
end
