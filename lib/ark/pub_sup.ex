defmodule Ark.PubSup do
  use GenServer

  @mod inspect(__MODULE__)

  @doc false
  def __ark__(:doc) do
    """
    This module provides a simple pub-sub mechanism for processes under a
    common supervisor.
    """
  end

  def subscribe(topic),
    do: subscribe(get_server(), topic)

  def subscribe(server, topic) when is_pid(server) do
    GenServer.call(server, {:subscribe, topic, self()})
  end

  def publish(topic, value),
    do: publish(get_server(), topic, value)

  def publish(server, topic, value) when is_pid(server) do
    GenServer.call(server, {:publish, topic, value})
  end

  # defp get_server() do
  #   IO.inspect(Process.get(), label: "Process.get()")

  #   server =
  #     get_server_2
  #     |> IO.inspect(label: "server")
  # end

  defp get_server() do
    case Process.get(__MODULE__) do
      nil ->
        sup = get_parent_sup()

        children =
          try do
            # Supervisor.which_children does not support timeouts
            GenServer.call(sup, :which_children, 5000)
          catch
            :exit, {:timeout, {GenServer, :call, [_, :which_children, _]}} ->
              raise """
              Timeout in #{@mod} while fetching supervisor
              children.

              Make sure you do not call Ark.PubSup.subscribe/1 in the init/1
              function of your GenServer.
              """
          end

        server = find_pub_sup(children)
        Process.put(__MODULE__, server)
        server

      pid when is_pid(pid) ->
        pid
    end
  end

  defp get_parent_sup() do
    case Process.get(:"$ancestors") do
      [sup | _] -> sup
      _ -> raise "Could not find parent supervisor"
    end
  end

  defp find_pub_sup([{Ark.PubSup, :undefined, _, _} | _]),
    do: raise("Supervisor's #{@mod} child is not started")

  defp find_pub_sup([{Ark.PubSup, pid, _, _} | _]) when is_pid(pid),
    do: pid

  defp find_pub_sup([_ | children]),
    do: find_pub_sup(children)

  defp find_pub_sup([]),
    do: raise("Supervisor has no #{@mod} child")

  # -- Pub sub server implementation ------------------------------------------

  def start_link(_) do
    GenServer.start_link(__MODULE__, [])
  end

  def init(_) do
    {:ok, %{}}
  end

  def handle_call({:subscribe, topic, client}, from, state) do
    GenServer.reply(from, :ok)

    clients =
      case state do
        %{^topic => clients} -> clients
        _ -> []
      end

    clients =
      if Enum.member?(clients, client) do
        clients
      else
        Process.monitor(client)
        [client | clients]
      end

    state = Map.put(state, topic, clients)
    {:noreply, state}
  end

  def handle_call({:publish, topic, value}, from, state) do
    GenServer.reply(from, :ok)

    state
    |> Map.get(topic, [])
    |> Enum.map(fn client -> send(client, {__MODULE__, topic, value}) end)

    {:noreply, state}
  end

  def handle_info({:DOWN, _, :process, pid, _}, state) do
    # A child is dead, we must remove it from all our topics.
    state =
      for {topic, clients} <- state, into: %{} do
        {topic, List.delete(clients, pid)}
      end

    {:noreply, state}
  end
end
