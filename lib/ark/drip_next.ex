defmodule Ark.DripNext do
  use GenServer
  alias :queue, as: Q

  @doc false
  def __ark__(:doc) do
    """
    This module implements a `GenServer` and allows to throttle calls
    to a common resource.
    """
  end

  @moduledoc false

  # New implementation based on a sliding time window.
  #
  # First implementation used a list of times for slots, then we used spawned
  # processes to await the slots.
  #
  # Now we will simply use maths.

  def start_link(opts) do
    {gen_opts, opts} = normalize_opts(opts)
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def start(opts) do
    {gen_opts, opts} = normalize_opts(opts)
    GenServer.start(__MODULE__, opts, gen_opts)
  end

  defp normalize_opts(opts) do
    {gen_opts, opts} = split_gen_opts(opts)

    # support tuple :spec param
    opts =
      case Keyword.pop(opts, :spec) do
        {{max_drips, range_ms}, opts} ->
          opts
          |> Keyword.put(:range_ms, range_ms)
          |> Keyword.put(:max_drips, max_drips)

        {nil, opts} ->
          opts
      end

    {gen_opts, opts}
  end

  defp split_gen_opts(opts) when is_list(opts) do
    Keyword.split(opts, [:debug, :name, :timeout, :spawn_opt, :hibernate_after])
  end

  def stop(bucket) do
    GenServer.stop(bucket)
  end

  def await(bucket, timeout \\ :infinity)

  def await(bucket, :infinity) do
    GenServer.call(bucket, :await, :infinity)
  end

  IO.warn("""
  use a ref alias instead of self() in order to cancel only the given drip. Even
  though await() is blocking, it is more safe.
  """)

  def await(bucket, timeout) do
    try do
      GenServer.call(bucket, :await, timeout)
    catch
      :exit, e ->
        cancel(bucket, self())
        exit(e)
    end
  end

  def cancel(bucket, pid) when is_pid(pid) do
    GenServer.cast(bucket, {:cancel, pid})
  end

  defmodule S do
    @enforce_keys [
      :current_drips,
      :max_drips,
      :unit_ms,
      :offset,
      :base_time,
      :clients,
      :debug_offset
    ]
    defstruct @enforce_keys
  end

  @doc false
  def init(opts) do
    with {:ok, opts} <- validate_opts(opts) do
      max_drips = Keyword.fetch!(opts, :max_drips)
      range_ms = Keyword.fetch!(opts, :range_ms)
      offset = range_ms

      state = %S{
        current_drips: 0,
        max_drips: max_drips,
        unit_ms: div(range_ms, max_drips),
        offset: offset,
        base_time: now_ms() - offset,
        clients: Q.new(),
        debug_offset: now_ms()
      }

      {:ok, state}
    end
  end

  defp validate_opts(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, range_ms} <- Keyword.fetch(opts, :range_ms),
         {:ok, max_drips} <- Keyword.fetch(opts, :max_drips) do
      cond do
        max_drips < 1 ->
          {:stop, "Minimum drip per period is 1, got: #{inspect(max_drips)}"}

        range_ms < 1 ->
          {:stop, "Minimum period is 1, got: #{inspect(range_ms)}"}

        true ->
          {:ok, opts}
      end
    else
      _ -> {:stop, {:invalid_opts, opts}}
    end
  end

  @impl GenServer
  def handle_call(:await, from, state) do
    {:noreply, enqueue_client(state, from), {:continue, :manage_queue}}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    check_queue(state, "timeout")
  end

  @impl GenServer
  def handle_continue(:manage_queue, state) do
    check_queue(state, "continue")
  end

  def check_queue(state, check_reason) do
    now = now_ms()
    debug(state, now, check_reason)

    if :queue.is_empty(state.clients) do
      debug(state, now, "empty")
      {:noreply, state}
    else
      # When requested for a drip, we will check if there is enough time between
      # our base time and now to fit a drip.
      #
      # The base time is the time when all current drips are finished or the
      # current time (now) minus the offset, whichever is highest.

      base_time = max(now - state.offset, state.base_time)
      debug(state, state.base_time, "base time")
      manage_queue(state, {base_time, state.unit_ms, now}, Q.out(state.clients))
    end
  end

  defp manage_queue(state, {base_time, unit_ms, now}, {{:value, client}, new_queue}) do
    next_base_time = base_time + unit_ms

    if next_base_time > now do
      # the drip does not fit, we enqueue the client and keep our current base
      # time.
      timeout = next_base_time - now
      # we must replace the client in the queue, at the front, when storing the
      # new queue in state.
      state = %S{state | clients: Q.in_r(client, new_queue)}
      debug(state, now, "no fit, await #{timeout}")
      {:noreply, state, timeout}
    else
      # the drip fits, we can tell our client and update our base time, then
      # continue with the next in queue
      debug(state, now, "* drip")
      GenServer.reply(client, :ok)
      # then we "consume" time by adding one range to the current base time.
      # at some point it will be higher than "now" and we will stop
      manage_queue(state, {next_base_time, unit_ms, now}, Q.out(new_queue))
    end
  end

  defp manage_queue(state, {base_time, _, _}, {:empty, new_queue}) do
    {:noreply, %S{state | clients: new_queue, base_time: base_time}}
  end

  def handle_cast({:cancel, pid}, state) do
    clients =
      Q.filter(
        fn
          {^pid, _} -> false
          _ -> true
        end,
        state.clients
      )

    {:noreply, %S{state | clients: clients}}
  end

  defp enqueue_client(state, client) do
    %S{state | clients: Q.in(client, state.clients)}
  end

  def now_ms do
    :erlang.system_time(:millisecond)
  end

  defp debug(%S{debug_offset: root}, at, reason) do
    IO.puts("[debug] #{at - root}: #{reason}")
  end
end
