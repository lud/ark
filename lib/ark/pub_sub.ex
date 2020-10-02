defmodule Ark.PubSub do
  use GenServer

  require Record
  require Logger
  Record.defrecordp(:rsub, :subscription, pid: nil, tag: __MODULE__)
  Record.defrecordp(:rcnfo, :client_info, topic: nil, tag: __MODULE__)

  @default_tag __MODULE__
  @cleanup_timeout 10_000

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

  def unsubscribe(ps, topic, tag \\ @default_tag) do
    GenServer.call(ps, {:unsubscribe, self(), topic, tag})
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
    {:ok, %{topic2subs: %{}, properties: %{}, clients: %{}}}
  end

  @impl GenServer
  def handle_call({:subscribe, client, topic, opts}, from, state) do
    GenServer.reply(from, :ok)

    Process.link(client)

    # Create the subscription data
    sub = rsub(pid: client, tag: opts[:tag] || @default_tag)

    state = add_subscription(state, topic, sub)

    # If the topic is a property, we will immediately send the current value.
    # Note we send the full :property tuple as the topic, since it IS the topic.
    case topic do
      {:property, key} -> send_event(sub, topic, state.properties[key])
      _ -> :ok
    end

    {:noreply, state, @cleanup_timeout}
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

    {:noreply, state, @cleanup_timeout}
  end

  def handle_call({:unsubscribe, pid, topic, tag}, from, state) do
    GenServer.reply(from, :ok)

    state = delete_subcription(state, pid, topic, tag)

    {:noreply, state, @cleanup_timeout}
  end

  def handle_call({:clear, pid}, from, state) do
    GenServer.reply(from, :ok)
    {:noreply, clear_pid(state, pid), @cleanup_timeout}
  end

  @impl GenServer
  def handle_info({:EXIT, pid, _}, state) do
    {:noreply, clear_pid(state, pid), @cleanup_timeout}
  end

  def handle_info(:timeout, state) do
    {:noreply, cleanup(state), :infinity}
  end

  defp send_event(rsub(pid: pid, tag: tag), topic, value),
    do: send(pid, {tag, topic, value})

  defp add_subscription(state, topic, sub) do
    rsub(pid: pid, tag: tag) = sub
    client_info = rcnfo(topic: topic, tag: tag)

    state
    # store the sub (pid+tag) under the topic
    |> update_in([:topic2subs, Access.key(topic, [])], &[sub | &1 -- [sub]])
    # store the topic+tag under the pid
    |> update_in([:clients, Access.key(pid, [])], &[client_info | &1 -- [client_info]])
  end

  defp delete_subcription(state, pid, topic, tag) do
    sub = rsub(pid: pid, tag: tag)
    client_info = rcnfo(topic: topic, tag: tag)

    state =
      state
      # Delete the subscription from the topic
      |> update_in([:topic2subs, Access.key(topic, [])], &(&1 -- [sub]))
      # Delete the client_info from the client
      |> update_in([:clients, Access.key(pid, [])], &(&1 -- [client_info]))

    # If there is no more subscription for this client we can unlink it
    case state.clients[pid] do
      [] -> Process.unlink(pid)
      _ -> :ok
    end

    state
  end

  defp clear_pid(state, pid) do
    Process.unlink(pid)

    client_infos = Map.get(state.clients, pid, [])

    # topic2subs =
    #   for rcnfo(topic: client_topic, tag: tag) <- Map.get(state.clients, pid, []),
    #       reduce: state.topic2subs do
    #     t2s -> Map.update!(t2s, client_topic, &(&1 -- [rsub(pid: pid, tag: tag)]))
    #   end
    topic2subs =
      Enum.reduce(
        client_infos,
        state.topic2subs,
        fn rcnfo(topic: client_topic, tag: tag), t2s ->
          Map.update!(t2s, client_topic, &(&1 -- [rsub(pid: pid, tag: tag)]))
        end
      )

    %{state | topic2subs: topic2subs}
  end

  defp cleanup(state) do
    %{
      state
      | topic2subs: remove_empty_lists(state.topic2subs),
        clients: remove_empty_lists(state.clients),
        properties: remove_nils(state.properties)
    }
  end

  defp remove_empty_lists(map) when is_map(map) do
    Enum.filter(map, fn
      {_, []} -> false
      _ -> true
    end)
    |> Enum.into(%{})
  end

  defp remove_nils(map) when is_map(map) do
    Enum.filter(map, fn
      {_, nil} -> false
      _ -> true
    end)
    |> Enum.into(%{})
  end
end

defmodule Ark.PubSub.Group do
  # This feature is not public, and is likely to be removed
  @moduledoc false
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
