defmodule Ark.PupSupTest do
  use ExUnit.Case, async: true

  defmodule Child do
    use GenServer, restart: :transient
    require Logger

    def start_link([test_pid, name]) do
      GenServer.start_link(__MODULE__, [test_pid, name])
    end

    def init([test_pid, name]) when is_pid(test_pid) do
      Logger.debug("Starting child #{name}: #{inspect(self())}")
      Ark.PubSup.subscribe(:test_topic)
      Logger.debug("Subscribed child #{name}: #{inspect(self())}")

      {:ok, test_pid}
    end

    def handle_info({Ark.PubSup, topic, value}, test_pid) do
      send(test_pid, {:received, self(), {topic, value}})
      {:noreply, test_pid}
    end

    def handle_info(msg, test_pid) do
      Logger.warn("handle_info: #{inspect(msg)}")
      {:noreply, test_pid}
    end
  end

  defmodule Sup do
    use Supervisor
    # use Ark.PubSup

    def start_link(init_arg) do
      Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
    end

    @impl true
    def init(_init_arg) do
      children = []

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  test "communicate between processes" do
    {:ok, sup} = Supervisor.start_link(Sup, [])
    {:ok, ps} = Supervisor.start_child(sup, Ark.PubSup)

    {:ok, child_a} =
      Supervisor.start_child(
        sup,
        Supervisor.child_spec({Child, [self(), :child_a]}, id: :child_a)
      )

    {:ok, child_b} =
      Supervisor.start_child(
        sup,
        Supervisor.child_spec({Child, [self(), :child_b]}, id: :child_b)
      )

    # Subscribe child a and not child_b
    Ark.PubSup.publish(ps, :test_topic, :hello)
    assert_receive {:received, ^child_a, {:test_topic, :hello}}
    refute_receive {:received, ^child_b, {:test_topic, :hello}}

    Ark.PubSup.publish(ps, :test_topic, :hi)
    assert_receive {:received, ^child_a, {:test_topic, :hi}}
    assert_receive {:received, ^child_b, {:test_topic, :hi}}
  end
end
