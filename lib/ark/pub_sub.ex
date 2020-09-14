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
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:subscribe, client, topic, opts}, from, state) do
    GenServer.reply(from, :ok)
    sub = rsub(pid: client, tag: opts[:tag] || __MODULE__)

    subs =
      case state do
        %{^topic => subs} -> subs
        _ -> []
      end

    state = Map.put(state, topic, add_subscription(subs, sub))
    {:noreply, state}
  end

  def handle_call({:publish, topic, value}, from, state) do
    GenServer.reply(from, :ok)

    state
    |> Map.get(topic, [])
    |> Enum.map(fn rsub(pid: pid, tag: tag) -> send(pid, {tag, topic, value}) end)

    {:noreply, state}
  end

  def handle_call({:clear, pid}, from, state) do
    GenServer.reply(from, :ok)
    {:noreply, clear_pid(state, pid)}
  end

  @impl GenServer
  def handle_info({:DOWN, _, :process, pid, _}, state) do
    # A child is dead, we must remove it from all our topics.
    state = clear_pid(state, pid)
    {:noreply, state}
  end

  defp add_subscription(subs, sub, monitored? \\ false)

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

  defp clear_pid(state, pid) do
    for {topic, subs} <- state, into: %{} do
      subs = Enum.filter(subs, fn rsub(pid: p) -> p != pid end)

      {topic, subs}
    end
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
