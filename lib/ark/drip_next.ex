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
    GenServer.call(bucket, {:await, make_ref()}, :infinity)
  end

  def await(bucket, timeout) do
    ref = make_ref()

    try do
      GenServer.call(bucket, {:await, ref}, timeout)
    catch
      :exit, e ->
        cancel(bucket, ref)
        exit(e)
    end
  end

  def cancel(bucket, pid) when is_reference(pid) do
    GenServer.cast(bucket, {:cancel, pid})
  end

  defmodule S do
    @enforce_keys [
      # maximum drips for the time window
      :max_drips,
      # width of the time window
      :range_ms,
      # dispatched drips for the current window
      :used,
      # timestamp at which the next windows will start
      :next_reset,
      # a queue to buffer demands when there is no available drip
      :clients,
      # a timestamp to remove from timed logs to get log time relative to the
      # init() call
      :debug_offset
    ]
    defstruct @enforce_keys
  end

  @impl GenServer
  def init(opts) do
    with {:ok, opts} <- validate_opts(opts) do
      max_drips = Keyword.fetch!(opts, :max_drips)
      range_ms = Keyword.fetch!(opts, :range_ms)

      # for each time window we send ourselves a reset
      :timer.send_interval(range_ms, :reset, max_drips)

      state = %S{
        max_drips: max_drips,
        range_ms: range_ms,
        used: 0,
        next_reset: now_ms() + range_ms,
        clients: Q.new(),
        debug_offset: now_ms() + range_ms
      }

      {:ok, state, range_ms}
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
  def handle_call({:await, _ref}, _from, %S{used: used, max_drips: max} = state)
      when used < max do
    {:reply, :ok, %S{state | used: used + 1}, next_timeout(state)}
  end

  def handle_call({:await, ref}, from, %S{} = state) do
    state = enqueue_client(state, {from, ref})
    {:noreply, state, next_timeout(state)}
  end

  @impl GenServer
  def handle_info(:timeout, %S{} = state) do
    # when starting a new window we will use the previous "next_reset" as "now".
    # This will compensate for messaging and calculations (queuing, timeouts) by
    # using slightly lesser windows
    %S{range_ms: range_ms, next_reset: next_reset} = state
    now = next_reset
    next_reset = now + range_ms
    state = %S{state | used: 0, next_reset: next_reset}
    state = run_queue(state)
    {:noreply, state, next_timeout(state)}
  end

  defp run_queue(%S{clients: q, used: used, max_drips: max} = state)
       when used < max do
    case Q.out(q) do
      {:empty, _} ->
        state

      {{:value, {from, _}}, new_q} ->
        GenServer.reply(from, :ok)
        run_queue(%S{state | used: used + 1, clients: new_q})
    end
  end

  defp run_queue(%S{} = state) do
    state
  end

  @impl GenServer
  def handle_cast({:cancel, ref}, %S{} = state) do
    clients =
      Q.filter(
        fn
          {_from, ^ref} -> false
          _ -> true
        end,
        state.clients
      )

    {:noreply, %S{state | clients: clients}}
  end

  defp enqueue_client(state, client) do
    q = Q.in(client, state.clients)
    %S{state | clients: q}
  end

  def now_ms do
    :erlang.system_time(:millisecond)
  end

  defp next_timeout(%{next_reset: next}), do: max(0, next - now_ms())
end
