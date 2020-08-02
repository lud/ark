defmodule Ark.OkTest do
  use ExUnit.Case, async: true
  import Ark.Ok

  test "wrapping ok" do
    assert {:ok, 1} = ok(1)
    assert :ok = ok(:ok)
    assert {:ok, 1} = ok({:ok, 1})
    assert {:error, :reason} = ok({:error, :reason})
    assert {:error, :reason, :a} = ok({:error, :reason, :a})
    assert {:error, :reason, :a, :b} = ok({:error, :reason, :a, :b})
  end

  test "unwrapping ok" do
    assert 1 = uok({:ok, 1})
    assert 1 = uok(1)
    assert :ok = uok(:ok)
    assert {:error, :reason} = uok({:error, :reason})
    assert {:error, :reason, :a} = uok({:error, :reason, :a})
    assert {:error, :reason, :a, :b} = uok({:error, :reason, :a, :b})
  end

  test "unwrapping raise" do
    assert 1 = uok!({:ok, 1})
    assert :ok = uok!(:ok)
    assert_raise Ark.Ok.UnwrapError, "Could not unwrap value: 1", fn -> uok!(1) end
    assert_raise Ark.Ok.UnwrapError, fn -> uok!({:error, :reason}) end
    assert_raise Ark.Ok.UnwrapError, fn -> uok!({:error, :reason, :a}) end
    assert_raise Ark.Ok.UnwrapError, fn -> uok!({:error, :reason, :a, :b}) end
  end

  test "questionning ok" do
    refute ok?(1)
    assert ok?(:ok)
    assert ok?({:ok, 1})
    refute ok?({:error, :reason})
    refute ok?({:error, :reason, :a})
    refute ok?({:error, :reason, :a, :b})
  end
end
