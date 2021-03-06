defmodule Ark.DripTest do
  use ExUnit.Case, async: true
  alias Ark.Drip

  defmodule H do
    def task(drip, id) do
      Task.async(fn ->
        :ok = Drip.await(drip)
        IO.puts("drop [#{id}] #{inspect(self())} #{:erlang.system_time(:second)}")
      end)
    end

    def task_timeout(drip, id, timeout) do
      Task.async(fn ->
        IO.puts("await [#{id}] timeout=#{timeout}")

        try do
          :ok = Drip.await(drip, timeout)
          IO.puts("drop [#{id}] #{inspect(self())} #{:erlang.system_time(:second)}")
          :ok
        catch
          :exit, _ ->
            IO.puts("exit [#{id}]")

            receive do
              msg ->
                IO.puts("received after timeout: [#{id}] #{inspect(msg)}")
                # assert false
            after
              3000 ->
                :ok
            end

            :timeout
        end
      end)
    end
  end

  test "drip" do
    Drip.start_link([max_drips: 10, range_ms: 1000], name: __MODULE__.Drip)
    t1 = :erlang.monotonic_time(:millisecond)

    tasks =
      for n <- 1..20 do
        H.task(__MODULE__.Drip, n)
      end

    IO.puts("awaiting")
    tasks |> Enum.map(&Task.await(&1, :infinity))
    t2 = :erlang.monotonic_time(:millisecond)
    # 20 drips at 10 per second should take at least 1 seconds
    # but less thant 2 seconds, since at time 0 we can run 10 tasks, 
    # and at time 1 we can run the last 10
    assert t2 - t1 > 1000 * (div(20, 10) - 1)
    assert t2 - t1 < 1000 * div(20, 10)
  end

  test "1 drip slow" do
    Drip.start_link([max_drips: 1, range_ms: 1_000], name: __MODULE__.DripSlow)
    # The first call should be immediate and the second should wait
    # 1000 ms
    t1 = :erlang.monotonic_time(:millisecond)
    H.task(__MODULE__.DripSlow, :slow_1) |> Task.await()
    H.task(__MODULE__.DripSlow, :slow_2) |> Task.await()
    t2 = :erlang.monotonic_time(:millisecond)
    assert t2 - t1 > 1000
    assert t2 - t1 < 1100
    # If the Drip is idle (time is waited long before), the call should be
    # immediate, so we expect it took least than 10 ms
    Process.sleep(1_000)
    t1 = :erlang.monotonic_time(:millisecond)
    H.task(__MODULE__.DripSlow, :slow_3) |> Task.await()
    t2 = :erlang.monotonic_time(:millisecond)
    assert t2 - t1 < 10
  end

  test "drip timeout" do
    {:ok, pid} = Drip.start_link([max_drips: 10, range_ms: 1000], name: nil)

    # Run different batches :
    # - batch 1 (20) with a timeout of 500 will have 10 tasks ok and 10 taks timeout
    #   => 1000 ms will been elapsed before we can get a drip
    # - batch 2 (10) with a timeout of 1100 will have 10 tasks ok
    #   => 2000 ms will been elapsed before we can get a drip
    # - batch 3 (20) with timeout of 2500 wil have ok/fail 10/10

    batch_1 = for(n <- 1..20, do: H.task_timeout(pid, "A #{n}", 500))
    Process.sleep(50)
    batch_2 = for(n <- 1..10, do: H.task_timeout(pid, "B #{n}", 1200))
    Process.sleep(50)
    batch_3 = for(n <- 1..20, do: H.task_timeout(pid, "C #{n}", 2500))

    assert_batch(batch_1, 10, 10)
    assert_batch(batch_2, 10, 0)
    assert_batch(batch_3, 10, 10)
  end

  test "100 drips" do
    Drip.start_link([max_drips: 10, range_ms: 100], name: __MODULE__.Drip)
    t1 = :erlang.monotonic_time(:millisecond)

    tasks =
      for n <- 1..100 do
        H.task(__MODULE__.Drip, n)
      end

    IO.puts("awaiting")
    tasks |> Enum.map(&Task.await(&1, :infinity))
    t2 = :erlang.monotonic_time(:millisecond)

    assert t2 - t1 > 900
    assert t2 - t1 < 1100
  end

  defp assert_batch(tasks, expected_ok, expected_timeout) do
    {oks, tos} =
      tasks
      |> Enum.map(&Task.await(&1, :infinity))
      |> IO.inspect()
      |> Enum.split_with(&Ark.Ok.ok?/1)

    assert length(oks) == expected_ok
    assert length(tos) == expected_timeout
  end

  test "Drip under supervision" do
    children = [
      {Ark.Drip, spec: {10, 1100}}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: __MODULE__.TestSupervisor]
    assert {:ok, _} = Supervisor.start_link(children, opts)
  end
end
