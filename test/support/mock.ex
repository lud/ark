defmodule Ark.Test.Mock do
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  defmodule UnexpectedCallError do
    defexception [:message]
  end

  # The returned function raises when called more than `expected` times. As the
  # workflow engine catches raises from user code, `verify/1` is the reliable
  # check.
  def mock_fun(expected, impl)
      when is_integer(expected) and expected >= 0 and is_function(impl) do
    pid = start_agent(%{expected: expected, calls: []})
    {:arity, arity} = Function.info(impl, :arity)
    {pid, wrap(arity, pid, impl)}
  end

  defp wrap(0, pid, impl) do
    fn -> call(pid, impl, []) end
  end

  defp wrap(1, pid, impl) do
    fn a -> call(pid, impl, [a]) end
  end

  defp wrap(2, pid, impl) do
    fn a, b -> call(pid, impl, [a, b]) end
  end

  defp wrap(3, pid, impl) do
    fn a, b, c -> call(pid, impl, [a, b, c]) end
  end

  defp wrap(4, pid, impl) do
    fn a, b, c, d -> call(pid, impl, [a, b, c, d]) end
  end

  defp call(pid, impl, args) do
    {count, expected} =
      Agent.get_and_update(pid, fn %{calls: calls, expected: expected} = state ->
        {{length(calls) + 1, expected}, %{state | calls: [args | calls]}}
      end)

    if count > expected do
      raise UnexpectedCallError,
            "mock expected #{expected} calls, got call ##{count} with #{inspect(args)}"
    end

    apply(impl, args)
  end

  def verify(pid) do
    %{expected: expected, calls: calls} = Agent.get(pid, & &1)
    count = length(calls)

    if count != expected do
      ExUnit.Assertions.flunk(
        "mock expected #{expected} calls, got #{count}:\n\n" <>
          Enum.map_join(Enum.reverse(calls), "\n", &inspect/1)
      )
    end

    :ok
  end

  # Arguments of each call, in call order.
  def calls(pid) do
    pid |> Agent.get(& &1.calls) |> Enum.reverse()
  end

  # An ordered log shared by several pieces of user code, to check call order
  # across mocks and module functions.
  def start_log do
    start_agent([])
  end

  def track(log, term) do
    Agent.update(log, &[term | &1])
  end

  def logged(log) do
    log |> Agent.get(& &1) |> Enum.reverse()
  end

  defp start_agent(initial) do
    start_supervised!(Supervisor.child_spec({Agent, fn -> initial end}, id: make_ref()))
  end
end
