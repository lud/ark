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

  test "unwrapping ok" do
    assert 1 = uok({:ok, 1})
    assert 1 = uok(1)
    assert :ok = uok(:ok)
    assert :error = uok(:error)
    assert {:error, :reason} = uok({:error, :reason})
    assert {:error, :reason, :a} = uok({:error, :reason, :a})
    assert {:error, :reason, :a, :b} = uok({:error, :reason, :a, :b})
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

    assert {:error, {:bad_return, {no_tuple, [10]}, 10}} == map_ok(1..10, no_tuple)
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
  end
end
