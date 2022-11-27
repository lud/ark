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

  defmodule MyErrors do
    import Ark.Error

    def with_data(data), do: reason(:got_data, data)
    def without_data(), do: reason(:no_data)

    @doc false
    @spec format_reason(term, term) :: iodata
    def format_reason(:got_data, data) do
      "you gave me #{inspect(data)}"
    end

    def format_reason(:no_data, _) do
      "you gave me nothing"
    end
  end

  test "defining reasons" do
    assert {MyErrors, :got_data, 123} == MyErrors.with_data(123)
    assert {MyErrors, :no_data, nil} == MyErrors.without_data()

    assert "you gave me 123" = Error.to_string(MyErrors.with_data(123))
    assert "you gave me nothing" = Error.to_string(MyErrors.without_data())
  end
end
