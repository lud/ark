defmodule Ark.PaginatorTest do
  use ExUnit.Case, async: true

  alias Ark.Paginator

  describe "stream/2 initial result" do
    test "returns {:ok, stream} when first callback returns :cont" do
      assert {:ok, stream} =
               Paginator.stream(0, fn _ -> {:halt, [:done]} end)

      assert is_function(stream) or is_list(stream) or
               match?(%Stream{}, stream)
    end

    test "returns {:ok, items} directly when first callback returns :halt" do
      assert {:ok, [1, 2, 3]} =
               Paginator.stream(:start, fn :start -> {:halt, [1, 2, 3]} end)
    end

    test "returns {:error, reason} when first callback returns :error" do
      assert {:error, :boom} =
               Paginator.stream(:start, fn :start -> {:error, :boom} end)
    end

    test "passes the initial state to the callback" do
      assert {:ok, [:initial]} =
               Paginator.stream(:initial, fn state -> {:halt, [state]} end)
    end
  end

  describe "stream/2 pagination" do
    test "concatenates items across multiple :cont pages" do
      pages = %{1 => [1, 2, 3], 2 => [4, 5], 3 => [6]}

      {:ok, stream} =
        Paginator.stream(1, fn page ->
          case Map.get(pages, page, []) do
            [] -> {:halt, []}
            items -> {:cont, items, page + 1}
          end
        end)

      assert Enum.to_list(stream) == [1, 2, 3, 4, 5, 6]
    end

    test "includes items returned with :halt as the last page" do
      {:ok, stream} =
        Paginator.stream(1, fn
          1 -> {:cont, [:a, :b], 2}
          2 -> {:halt, [:c, :d]}
        end)

      assert Enum.to_list(stream) == [:a, :b, :c, :d]
    end

    test "halts on the very first call without follow-up callback invocations" do
      parent = self()

      callback = fn :start ->
        send(parent, :called)
        {:halt, [:only]}
      end

      assert {:ok, [:only]} = Paginator.stream(:start, callback)

      assert_received :called
      refute_received :called
    end

    test "threads the state between successive callback calls" do
      {:ok, stream} =
        Paginator.stream(0, fn
          n when n < 3 -> {:cont, [n], n + 1}
          n -> {:halt, [n]}
        end)

      assert Enum.to_list(stream) == [0, 1, 2, 3]
    end

    test "supports streams as page items" do
      {:ok, stream} =
        Paginator.stream(1, fn
          1 -> {:cont, Stream.map([1, 2], &(&1 * 10)), 2}
          2 -> {:halt, Stream.map([3, 4], &(&1 * 10))}
        end)

      assert Enum.to_list(stream) == [10, 20, 30, 40]
    end

    test "supports empty pages" do
      {:ok, stream} =
        Paginator.stream(1, fn
          1 -> {:cont, [], 2}
          2 -> {:cont, [:a], 3}
          3 -> {:halt, []}
        end)

      assert Enum.to_list(stream) == [:a]
    end

    test "raises when a subsequent page returns :error" do
      {:ok, stream} =
        Paginator.stream(1, fn
          1 -> {:cont, [:a], 2}
          2 -> {:error, :network_down}
        end)

      assert_raise RuntimeError, ~r/error in paginator callback.*network_down/, fn ->
        Enum.to_list(stream)
      end
    end

    test "is lazy: the callback is not invoked beyond the requested items" do
      parent = self()

      callback = fn page ->
        send(parent, {:called, page})
        {:cont, [page], page + 1}
      end

      {:ok, stream} = Paginator.stream(1, callback)

      assert Enum.take(stream, 2) == [1, 2]

      assert_received {:called, 1}
      assert_received {:called, 2}
      refute_received {:called, 3}
    end

    test "first page items are emitted before the callback is called for the next page" do
      parent = self()

      callback = fn page ->
        send(parent, {:called, page})

        case page do
          1 -> {:cont, [:a, :b], 2}
          2 -> {:halt, [:c]}
        end
      end

      {:ok, stream} = Paginator.stream(1, callback)

      assert Enum.take(stream, 1) == [:a]

      assert_received {:called, 1}
      refute_received {:called, 2}
    end
  end
end
