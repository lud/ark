defmodule Ark.OkTest do
  use ExUnit.Case, async: true
  import Ark.Ok

  test "wrapping ok" do
    assert {:ok, 1} = ok(1)
    assert :ok = ok(:ok)
    assert {:ok, 1} = ok({:ok, 1})
    assert :error = ok(:error)
    assert {:error, :reason} = ok({:error, :reason})
    assert {:error, :reason, :a} = ok({:error, :reason, :a})
    assert {:error, :reason, :a, :b} = ok({:error, :reason, :a, :b})
  end

  test "unwrapping raise" do
    assert 1 = uok!({:ok, 1})
    assert :ok = uok!(:ok)
    assert_raise Ark.Ok.UnwrapError, "Could not unwrap value: 1", fn -> uok!(1) end
    assert_raise Ark.Ok.UnwrapError, fn -> uok!(:error) end
    assert_raise Ark.Ok.UnwrapError, fn -> uok!({:error, :reason}) end
    assert_raise Ark.Ok.UnwrapError, fn -> uok!({:error, :reason, :a}) end
    assert_raise Ark.Ok.UnwrapError, fn -> uok!({:error, :reason, :a, :b}) end
  end

  test "questionning ok" do
    assert ok?(:ok)
    assert ok?({:ok, 1})
    refute ok?(1)
    refute ok?(:error)
    refute ok?({:error, :reason})
    refute ok?({:error, :reason, :a})
    refute ok?({:error, :reason, :a, :b})
  end

  defmodule SampleError do
    defexception [:message]
  end

  test "exception unwrapping macro" do
    number = fn -> {:ok, 1} end
    isok = fn -> :ok end
    throws = fn -> {:error, %SampleError{message: "failure"}} end
    reason = fn -> {:error, :something_happened} end

    assert 1 = xok!(number.())
    assert :ok = xok!(isok.())

    assert_raise SampleError, fn ->
      xok!(throws.())
    end

    assert_raise Ark.Ok.UnwrapError, fn ->
      xok!(reason.())
    end
  end

  test "mapping while ok" do
    under_10 = fn
      v when v < 10 -> {:ok, v * v}
      _ -> {:error, :too_high}
    end

    assert {:ok, [1, 4, 9, 16]} == map_ok(1..4, under_10)
    assert {:error, :too_high} == map_ok(1..10, under_10)

    no_tuple = fn
      v when v < 10 -> {:ok, v * v}
      v -> v
    end

    assert_raise ArgumentError, ~r/unexpected 10, expected a result tuple from/, fn ->
      map_ok(1..10, no_tuple)
    end
  end

  test "mapping while ok – empty map" do
    assert {:ok, []} = map_ok([], fn _ -> raise "not happening" end)
  end

  test "flat mapping while ok" do
    expand = fn
      v when v < 5 -> {:ok, [v, v * 10]}
      _ -> {:error, :too_high}
    end

    assert {:ok, [1, 10, 2, 20, 3, 30]} == flat_map_ok(1..3, expand)
    assert {:error, :too_high} == flat_map_ok(1..5, expand)
  end

  test "flat mapping while ok – empty list" do
    assert {:ok, []} = flat_map_ok([], fn _ -> raise "not happening" end)
  end

  test "flat mapping while ok – callback returns empty lists" do
    assert {:ok, []} = flat_map_ok(1..3, fn _ -> {:ok, []} end)
  end

  test "flat mapping while ok – single level of flattening" do
    assert {:ok, [[1, 2], [3, 4], [1, 2], [3, 4]]} =
             flat_map_ok(1..2, fn _ -> {:ok, [[1, 2], [3, 4]]} end)
  end

  test "flat mapping while ok – error on first element" do
    bail = fn
      1 -> {:error, :foo}
      2 -> raise "should not be called"
    end

    assert {:error, :foo} == flat_map_ok([1, 2], bail)
  end

  test "flat mapping while ok – bad return value" do
    no_tuple = fn
      v when v < 3 -> {:ok, [v]}
      v -> v
    end

    assert_raise ArgumentError, ~r/unexpected 3, expected {:ok, list}/, fn ->
      flat_map_ok(1..3, no_tuple)
    end
  end

  test "flat mapping while ok – non-list value in ok tuple" do
    assert_raise ArgumentError, ~r/expected \{:ok, list\}/, fn ->
      flat_map_ok(1..3, fn v -> {:ok, v} end)
    end
  end

  test "reducing while ok" do
    # in this test we take some keys from a source map and move them to a target
    # map
    source = %{a: 1, b: 2, c: 2}
    target = %{}

    mover = fn key, {source, target} ->
      case Map.pop(source, key, :__not_found) do
        {:__not_found, _} -> {:error, {:not_found, key}}
        {value, source} -> {:ok, {source, Map.put(target, key, value)}}
      end
    end

    assert {:ok, {%{c: 2}, %{a: 1, b: 2}}} == reduce_ok([:a, :b], {source, target}, mover)

    assert {:error, {:not_found, :z}} == reduce_ok([:a, :b, :z], {source, target}, mover)

    no_tuple = fn
      key, {source, target} ->
        case Map.pop(source, key, :__not_found) do
          {:__not_found, _} -> :not_found
          {value, source} -> {:ok, {source, Map.put(target, key, value)}}
        end
    end

    assert_raise ArgumentError,
                 ~r/unexpected :not_found, expected a result tuple from/,
                 fn ->
                   reduce_ok([:a, :z], {source, target}, no_tuple)
                 end
  end

  test "reducint while ok – empty map" do
    assert {:ok, :hello} = reduce_ok([], :hello, fn _, _ -> raise "not happening" end)
  end
end
