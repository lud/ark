defmodule Ark.PupSubTest do
  use ExUnit.Case, async: false
  alias Ark.PubSub
  alias Ark.PubSub.Group

  test "can subscribe, publish and receive a message" do
    {:ok, ps} = PubSub.start_link()
    assert :ok = PubSub.subscribe(ps, :topic_1)
    assert :ok = PubSub.publish(ps, :topic_1, :hello)
    assert_receive {PubSub, :topic_1, :hello}

    # subscribe with the same options
    :ok = PubSub.subscribe(ps, :topic_1)
    :ok = PubSub.publish(ps, :topic_1, :hello)
    # we will receive the message only once
    assert_receive {PubSub, :topic_1, :hello}
    refute_receive {PubSub, :topic_1, :hello}

    # subscribe with a different tag
    :ok = PubSub.subscribe(ps, :topic_1, tag: :pubsub)
    :ok = PubSub.publish(ps, :topic_1, :hello)
    assert_receive {PubSub, :topic_1, :hello}
    refute_receive {PubSub, :topic_1, :hello}
    assert_receive {:pubsub, :topic_1, :hello}

    # clear the subscriptions
    assert :ok = PubSub.clear(ps)
    :ok = PubSub.publish(ps, :topic_1, :hello)
    refute_receive {PubSub, :topic_1, :hello}
    refute_receive {PubSub, :TOPIC_1, :hello}

    # Obviously we should not receive any message for a different topic, even if
    # we use our subscribed topic as a tag
    :ok = PubSub.subscribe(ps, :OTHER_TOPIC, tag: :pubsub)
    :ok = PubSub.subscribe(ps, :OTHER_TOPIC, tag: :pubsub)
    :ok = PubSub.publish(ps, :topic_1, :hello)
    refute_receive {PubSub, :topic_1, :hello}
    refute_receive {PubSub, :TOPIC_1, :hello}
  end

  # Utility code to test the group system

  defmodule Child do
    use GenServer, restart: :transient
    require Logger

    def start_link([name]) do
      GenServer.start_link(__MODULE__, [name])
    end

    def check(pid) do
      GenServer.call(pid, :check)
    end

    def check(pid, msg) do
      pid
      |> GenServer.call(:check)
      |> Enum.member?(msg)
    end

    def init([name]) do
      Group.subscribe(:init_test_topic, async: true, tag: :pubsub)
      Group.subscribe(:counter, async: true, tag: :pubsub)
      Logger.debug("Subscribed child #{name}: #{inspect(self())}")

      {:ok, []}
    end

    def handle_call(:check, _, msgs) do
      {:reply, :lists.reverse(msgs), msgs}
    end

    # intercept counter messages lower than 4. From 4, messages will be
    # handled like any other and verifiables with check/1-2.
    # With more than 1 running GenServer, each message will be multiplied by
    # the amount of gen servers, this will lead to a LOT of messages.
    def handle_info({:pubsub, :counter, n} = msg, msgs) when is_integer(n) and n < 4 do
      Group.publish(:counter, n + 1)
      {:noreply, msgs}
    end

    def handle_info({Ark.PubSub.Group, topic, :"$subscribed"}, msgs) do
      {:noreply, [{topic, :"$subscribed"} | msgs]}
    end

    def handle_info({:pubsub, topic, msg}, msgs) do
      Logger.warn("received: #{inspect({topic, msg})}")
      {:noreply, [{topic, msg} | msgs]}
    end

    def handle_info(msg, test_pid) do
      Logger.warn("handle_info: #{inspect(msg)}")
      {:noreply, test_pid}
    end
  end

  test "pubsub group under supervisor" do
    assert {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)
    assert {:ok, ps} = Supervisor.start_child(sup, PubSub)

    assert {:ok, child_a} =
             Supervisor.start_child(
               sup,
               Supervisor.child_spec({Child, [:child_a]}, id: :child_a)
             )

    # Ensure that the child is started and subscribed
    assert_check(child_a, {:init_test_topic, :"$subscribed"})

    PubSub.publish(ps, :init_test_topic, "Hi !")
    assert_check(child_a, {:init_test_topic, "Hi !"})

    # Check the counter mechanism

    assert {:ok, child_b} =
             Supervisor.start_child(
               sup,
               Supervisor.child_spec({Child, [:child_b]}, id: :child_b)
             )

    PubSub.publish(ps, :counter, 0)
    assert_check(child_a, {:counter, 4})
    assert_check(child_b, {:counter, 4})
  end

  defp assert_check(pid, msg), do: assert_check(pid, msg, 4)

  defp assert_check(pid, msg, 0) do
    flunk("Child #{inspect(pid)} did not receive #{inspect(msg)} in time")
  end

  defp assert_check(pid, msg, retries) do
    if Child.check(pid, msg) do
      assert true
    else
      Process.sleep(40)
      assert_check(pid, msg, retries - 1)
    end
  end
end
