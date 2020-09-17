defmodule Ark.PubSub do
  use GenServer

  require Record
  require Logger
  Record.defrecordp(:rsub, pid: nil, tag: __MODULE__)

  @doc false
  def __ark__(:doc) do
    """
    This module provides a simple pub-sub mechanism.
    """
  end

  def subscribe(ps, topic, opts \\ []),
    do: subscribe(ps, self(), topic, opts)

  def subscribe(ps, client, topic, opts) do
    GenServer.call(ps, {:subscribe, client, topic, opts})
  end

  def clear(ps, pid \\ self()),
    do: GenServer.call(ps, {:clear, pid})

  def publish(ps, topic, value) do
    GenServer.call(ps, {:publish, topic, value})
  end

  # -- Pub sub server implementation ------------------------------------------

  def start_link(otp_opts \\ []) do
    GenServer.start_link(__MODULE__, [], otp_opts)
  end

  def start(otp_opts \\ []) do
    GenServer.start(__MODULE__, [], otp_opts)
  end

  @impl GenServer
  def init(_) do
    # We will trap exits so clients can be linked to us (on demand) and exit
    # if their source of events (us) goes down.
    Process.flag(:trap_exit, true)
    {:ok, %{topic2subs: %{}, properties: %{}}}
  end

  @impl GenServer
  def handle_call({:subscribe, client, topic, opts}, from, state) do
    GenServer.reply(from, :ok)

    # On demand, we will link to the client process and make it exit if we exit.
    if opts[:link] do
      Process.link(client)
    end

    # Create the subscription data
    sub = rsub(pid: client, tag: opts[:tag] || __MODULE__)

    # If the topic is a property, we will immediately send the current value.
    # Note we send the full :property tuple as the topic, since it IS the topic.
    case topic do
      {:property, key} -> send_event(sub, topic, state.properties[key])
      _ -> :ok
    end

    # Add the subscription in the list for the given topic
    subs =
      case state.topic2subs do
        %{^topic => subs} -> subs
        _ -> []
      end

    state = put_in(state.topic2subs[topic], add_subscription(subs, sub, opts[:link] || false))

    {:noreply, state}
  end

  def handle_call({:publish, topic, value}, from, state) do
    GenServer.reply(from, :ok)

    state.topic2subs
    |> Map.get(topic, [])
    |> Enum.map(fn sub -> send_event(sub, topic, value) end)

    # If the topic is a property, we will store the property key in the state
    state =
      case topic do
        {:property, key} -> put_in(state.properties[key], value)
        _ -> state
      end

    {:noreply, state}
  end

  def handle_call({:clear, pid}, from, state) do
    GenServer.reply(from, :ok)
    {:noreply, clear_pid(state, pid)}
  end

  @impl GenServer
  def handle_info({:DOWN, _, :process, pid, _}, state) do
    {:noreply, clear_pid(state, pid)}
  end

  def handle_info({:EXIT, pid, _}, state) do
    {:noreply, clear_pid(state, pid)}
  end

  defp send_event(rsub(pid: pid, tag: tag), topic, value),
    do: send(pid, {tag, topic, value})

  defp add_subscription(subs, sub, monitored?)

  # We foud the exact same subscription, we ignore the add
  defp add_subscription([sub | _] = list, sub, _),
    do: list

  # We found a subscription with the same pid, we will continue down the list
  # but we now know that the pid is already monitored
  defp add_subscription([rsub(pid: pid) = seen | rest], rsub(pid: pid) = sub, _),
    do: [seen | add_subscription(rest, sub, true)]

  defp add_subscription([seen | rest], sub, monitored?),
    do: [seen | add_subscription(rest, sub, monitored?)]

  defp add_subscription([], sub, monitored?) do
    unless monitored?, do: Process.monitor(rsub(sub, :pid))
    [sub]
  end

  defp clear_pid(%{topic2subs: t2s} = state, pid) do
    new_t2s =
      for {topic, subs} <- t2s, into: %{} do
        subs = Enum.filter(subs, fn rsub(pid: p) -> p != pid end)

        {topic, subs}
      end

    %{state | topic2subs: new_t2s}
  end

  defmodule Group do
    @group_pid {__MODULE__, :group_pid}
    @mod inspect(__MODULE__)

    def subscribe(topic, opts \\ []) do
      case get_cached_group() do
        {:ok, pid} -> Ark.PubSub.subscribe(pid, self(), topic, opts)
        :error -> subscribe_to_group(topic, opts)
      end
    end

    defp subscribe_to_group(topic, opts) do
      sup = get_parent_sup()
      client = self()

      if opts[:async] do
        spawn_link(fn ->
          subscribe_from_sup(sup, client, topic, opts, :infinity, fn _ ->
            send(client, {__MODULE__, topic, :"$subscribed"})
          end)
        end)

        :ok
      else
        subscribe_from_sup(sup, client, topic, opts, 5000, &put_cached_group/1)
      end
    end

    defp subscribe_from_sup(sup, client, topic, opts, timeout, fun) do
      ps = get_pubsub(sup, timeout, :subscribing)
      :ok = Ark.PubSub.subscribe(ps, client, topic, opts)
      fun.(ps)
    end

    def publish(topic, value) do
      case get_cached_group() do
        {:ok, pid} ->
          Ark.PubSub.publish(pid, topic, value)

        :error ->
          pubsub = get_pubsub(get_parent_sup(), 5000, :publishing)
          Ark.PubSub.publish(pubsub, topic, value)
      end
    end

    defp get_cached_group() do
      with pid when is_pid(pid) <- Process.get(@group_pid),
           true <- Process.alive?(pid) do
        {:ok, pid}
      else
        nil -> :error
        false -> :error
      end
    end

    defp put_cached_group(group_pid) do
      Process.put(@group_pid, group_pid)
      :ok
    end

    defp get_parent_sup() do
      case Process.get(:"$ancestors") do
        [sup | _] -> sup
        _ -> raise "Could not find parent supervisor"
      end
    end

    defp get_pubsub(sup, timeout, context) do
      children =
        try do
          # Supervisor.which_children does not support timeouts
          GenServer.call(sup, :which_children, timeout)
        catch
          :exit, {:timeout, {GenServer, :call, [_, :which_children, _]}} ->
            case context do
              :subscribing ->
                raise """
                Timeout while fetching supervisor children in #{@mod}.

                If you are calling this function from the init/1 callback of a
                GenServer (or equivalent), make sure to pass the `async: true` flag
                to #{@mod}.subscribe/2.
                """

              :publishing ->
                raise """
                Timeout while fetching supervisor children in #{@mod}.

                The async mechanism is not supported by #{@mod}.publish/2. Make sure
                you do not call this function from the init/1 callback of a
                GenServer (or equivalent). The `handle_continue/2` callback is
                available in `GenServer` to defer initialization tasks.
                """
            end
        end

      find_pubsub(children)
    end

    defp find_pubsub([{Ark.PubSub, :undefined, _, _} | _]),
      do: raise("Supervisor's #{@mod} child is not started")

    defp find_pubsub([{Ark.PubSub, pid, _, _} | _]) when is_pid(pid),
      do: pid

    defp find_pubsub([_ | children]),
      do: find_pubsub(children)

    defp find_pubsub([]),
      do: raise("Supervisor has no #{@mod} child")
  end
end
