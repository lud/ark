defmodule Ark.PubSubTest do
  use ExUnit.Case, async: true
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
    :ok = PubSub.subscribe(ps, :topic_1, tag: :my_tag)
    :ok = PubSub.publish(ps, :topic_1, :hello)
    assert_receive {PubSub, :topic_1, :hello}
    refute_receive {PubSub, :topic_1, :hello}
    assert_receive {:my_tag, :topic_1, :hello}

    # clear the subscriptions
    assert :ok = PubSub.clear(ps)
    :ok = PubSub.publish(ps, :topic_1, :hello)
    refute_receive {PubSub, :topic_1, :hello}
    refute_receive {:my_tag, :topic_1, :hello}

    # Obviously we should not receive any message for a different topic, even if
    # we use our subscribed topic as a tag
    :ok = PubSub.subscribe(ps, :OTHER_TOPIC, tag: :my_tag)
    :ok = PubSub.subscribe(ps, :OTHER_TOPIC, tag: :my_tag)
    :ok = PubSub.publish(ps, :topic_1, :hello)
    refute_receive {PubSub, :topic_1, :hello}
    refute_receive {:my_tag, :topic_1, :hello}
  end

  test "cannot have duplicate subscriptions" do
    topic = :dupes
    {:ok, ps} = PubSub.start_link()
    assert :ok = PubSub.subscribe(ps, topic, tag: :tag_dup)
    assert :ok = PubSub.subscribe(ps, topic, tag: :tag_dup)
    assert :ok = PubSub.subscribe(ps, topic, tag: :other)

    PubSub.publish(ps, topic, :hello)

    # Receive tagged with :tag_dup only once
    assert_receive {:tag_dup, ^topic, :hello}
    refute_receive {:tag_dup, ^topic, :hello}

    # Still receive tagged with :other tag
    assert_receive {:other, ^topic, :hello}
  end

  test "unsubscribe" do
    topic = :unsub
    {:ok, ps} = PubSub.start_link()
    assert :ok = PubSub.subscribe(ps, topic, tag: :tag_1)
    assert :ok = PubSub.subscribe(ps, topic, tag: :tag_2)
    assert :ok = PubSub.subscribe(ps, topic)

    PubSub.publish(ps, topic, :hello)
    assert_receive {:tag_1, ^topic, :hello}
    assert_receive {:tag_2, ^topic, :hello}
    assert_receive {PubSub, ^topic, :hello}

    # unsubscribe with tag
    assert :ok = PubSub.unsubscribe(ps, topic, :tag_1)
    PubSub.publish(ps, topic, :hello)
    assert_receive {:tag_2, ^topic, :hello}
    assert_receive {PubSub, ^topic, :hello}
    refute_receive {:tag_1, ^topic, :hello}

    # unsubscribe the default tag
    assert :ok = PubSub.unsubscribe(ps, topic)
    assert :ok = PubSub.publish(ps, topic, :hi!)
    assert_receive {:tag_2, ^topic, _}
    refute_receive {_, ^topic, _}
  end

  test "can clear process subscriptions" do
    topic = :clearable
    {:ok, ps} = PubSub.start_link()
    assert :ok = PubSub.subscribe(ps, topic)
    assert :ok = PubSub.publish(ps, topic, :hello)
    assert_receive {PubSub, ^topic, :hello}

    PubSub.clear(ps)
    assert :ok = PubSub.publish(ps, topic, :hi!)
    refute_receive {PubSub, ^topic, :hi!}
  end

  test "trapping exits and linking processes" do
    # We will test that when subscribing with the link option, if the PubSub
    # server terminates, a linked process will terminate (at least if it is not)
    # trapping exits. But if the subscriber terminates, the PubSub server will
    # stay alive (as it is trapping exits).
    {:ok, ps} = PubSub.start()
    topic = :killer_topic

    start_child = fn ->
      simple_child(
        fn ->
          PubSub.subscribe(ps, topic, tag: :my_tag)
          nil
        end,
        # we will keep the last value as state
        fn state, next ->
          receive do
            {:my_tag, ^topic, value} ->
              next.(value)

            {:get_last, from} ->
              send(from, {:last, state})
              next.(state)
          end
        end
      )
    end

    child1 = start_child.()
    PubSub.publish(ps, topic, :hello)
    send(child1, {:get_last, self()})
    assert_receive {:last, :hello}
    # Kill the child. The PS server must still be alive
    kill_sync(child1)
    refute Process.alive?(child1)
    assert Process.alive?(ps)

    child2 = start_child.()
    PubSub.publish(ps, topic, :hi!)
    send(child2, {:get_last, self()})
    assert_receive {:last, :hi!}
    # Kill the child. The PS server must still be alive.
    # We will kill it from a spawned process and not the test process which is
    # the ancestor (this is a special case)
    killer = spawn(fn -> kill_sync(ps) end)
    # await the killer
    await_down(killer)
    refute Process.alive?(child2)
    refute Process.alive?(ps)
  end

  test "properties are persistent events" do
    # When subscribing to a property, the last value of the property is
    # immediately published to the subscriber.
    # A property is simply an event where the topic is a 2-tuple tagged with
    # `:property`, i.e {:property, :my_topic}
    {:ok, ps} = PubSub.start_link()

    prop = {:property, :my_prop}
    topic = :some_topic

    parent = self()
    # Child will subscribe to the property and the topic. It will simply relay
    # all messages to the test process
    create_child = fn ->
      simple_child(
        fn ->
          :ok = PubSub.subscribe(ps, prop, tag: :my_tag)
          :ok = PubSub.subscribe(ps, topic, tag: :my_tag)
          nil
        end,
        # we will keep the last value as state
        fn state, next ->
          receive do
            {:my_tag, topic, value} ->
              send(parent, {self(), topic, value})
              next.(state)

            msg ->
              IO.puts("Unexpected msg: #{inspect(msg)}")
              next.(state)
          end
        end
      )
    end

    # So now we create the first child. It should report only the property with
    # a nil value since it has never been published yet.
    child1 = create_child.()

    # property is nil, topic is not persisted (refute)
    assert_receive {^child1, ^prop, nil}
    refute_receive {^child1, ^topic, _}

    # now we publish on the two topics
    PubSub.publish(ps, prop, :propval)
    PubSub.publish(ps, topic, :topicval)
    assert_receive {^child1, ^prop, :propval}
    assert_receive {^child1, ^topic, :topicval}

    # Kill the child and start another one
    kill_sync(child1)
    child2 = create_child.()
    # This time the child should receive the last property value upon
    # subscription, but no message for the normal topic.
    assert_receive {^child2, ^prop, :propval}
    refute_receive {^child2, ^topic, _}

    # nil is a valid value. We test the cleanup server-side
    PubSub.publish(ps, prop, nil)
    assert_receive {^child2, ^prop, nil}
  end

  defp simple_child(init, loop) when is_function(init, 0) and is_function(loop, 2) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        state = init.()
        send(parent, {:ack, ref})
        simple_child_loop(state, loop)
      end)

    receive do
      {:ack, ^ref} -> pid
    after
      1000 -> exit(:could_not_start_simple_child)
    end
  end

  defp simple_child_loop(state, loop) do
    loop.(state, fn state -> simple_child_loop(state, loop) end)
  end

  defp kill_sync(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      1000 -> exit({:could_not_kill_sync, pid})
    end
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      1000 -> exit({:process_is_not_DOWN, pid})
    end
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

    def init([_name]) do
      Group.subscribe(:init_test_topic, async: true, tag: :my_tag)
      Group.subscribe(:counter, async: true, tag: :my_tag)
      # Logger.debug("Subscribed child #{name}: #{inspect(self())}")

      {:ok, []}
    end

    def handle_call(:check, _, msgs) do
      {:reply, :lists.reverse(msgs), msgs}
    end

    # intercept counter messages lower than 4. From 4, messages will be
    # handled like any other and verifiables with check/1-2.
    # With more than 1 running GenServer, each message will be multiplied by
    # the amount of gen servers, this will lead to a LOT of messages.
    def handle_info({:my_tag, :counter, n}, msgs) when is_integer(n) and n < 4 do
      Group.publish(:counter, n + 1)
      {:noreply, msgs}
    end

    def handle_info({Ark.PubSub.Group, topic, :"$subscribed"}, msgs) do
      {:noreply, [{topic, :"$subscribed"} | msgs]}
    end

    def handle_info({:my_tag, topic, msg}, msgs) do
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
