defmodule Ark.PipeInTest do
  use ExUnit.Case, async: true
  use Ark
  doctest Ark.PipeIn

  test "Can pipe in a variable" do
    :test ~> v
    assert :test = v
  end

  test "Can pipe in a match" do
    {:ok, "value"} ~> {:ok, v}
    assert "value" = v
  end

  test "Can pipe from a pipe in a match" do
    "test"
    |> String.to_atom()
    |> ok()
    ~> {:ok, v}

    assert :test = v
  end

  test "Behaviour in the middle of a pipeline" do
    "test"
    |> String.to_atom()
    |> ok()
    ~> v0
    ~> {:ok, v1}
    |> inspect()
    ~> v2

    assert {:ok, :test} = v0
    assert :test = v1
    assert "{:ok, :test}" = v2
  end
end
