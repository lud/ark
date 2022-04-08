defmodule Ark.ErrorTest do
  use ExUnit.Case, async: true
  alias Ark.Error

  test "errors are unwrapped" do
    assert Error.to_string({:error, "hello"}) == Error.to_string("hello")
  end

  test "different kind of errors" do
    # Exception

    err =
      try do
        raise ArgumentError, "the message"
      rescue
        e -> e
      end

    assert "the message" == Error.to_string(err)

    # String

    assert "a string" == Error.to_string("a string")

    # Shutdown & atoms

    assert "(shutdown) stopped" == Error.to_string({:shutdown, "stopped"})
    assert "(shutdown) :stopped" == Error.to_string({:shutdown, :stopped})
  end
end
