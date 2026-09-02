defmodule Ark.ErrorTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Ark.Error
  doctest Ark.Error

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
    def with_data(data) do
      {__MODULE__, :got_data, data}
    end

    def without_data do
      {__MODULE__, :no_data, nil}
    end

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
    assert "you gave me 123" = Error.to_string(MyErrors.with_data(123), :public)
  end

  defmodule AudienceErrors do
    def format_reason(:known, data, audience) do
      "#{audience} #{data}"
    end

    def format_reason(other, data, audience) do
      Error.format_fallback(__MODULE__, other, data, audience)
    end
  end

  defmodule NoFormatter do
  end

  test "format_reason/3 receives the audience" do
    assert "private 1" == Error.to_string({AudienceErrors, :known, 1})
    assert "public 1" == Error.to_string({AudienceErrors, :known, 1}, :public)
  end

  test "format_fallback renders the triple for the audience" do
    assert "{Ark.ErrorTest.AudienceErrors, :unknown, 1}" ==
             Error.to_string({AudienceErrors, :unknown, 1})

    log =
      capture_log(fn ->
        assert "unknown error" == Error.to_string({AudienceErrors, :unknown, 1}, :public)
      end)

    assert log =~ "could not generate a public error message for"
    assert log =~ "{Ark.ErrorTest.AudienceErrors, :unknown, 1}"
  end

  test "modules without format_reason use the default fallback" do
    assert "{Ark.ErrorTest.NoFormatter, :tag, %{secret: 1}}" ==
             Error.to_string({NoFormatter, :tag, %{secret: 1}})

    log =
      capture_log(fn ->
        assert "unknown error" ==
                 Error.to_string({NoFormatter, :tag, %{secret: 1}}, :public)
      end)

    assert log =~ "%{secret: 1}"
  end

  test "private audience inspects unknown terms" do
    assert "%{secret: 1}" == Error.to_string({:error, %{secret: 1}})
    assert "%{secret: 1}" == Error.to_string({:error, %{secret: 1}}, :private)
    assert "[1, 2, 3]" == Error.to_string([1, 2, 3])
  end

  test "public audience renders atoms and numbers or a generic message" do
    assert ":timeout" == Error.to_string(:timeout, :public)
    assert "nil" == Error.to_string(nil, :public)
    assert "42" == Error.to_string({:error, 42}, :public)
    assert "(shutdown) :stopped" == Error.to_string({:shutdown, :stopped}, :public)

    log =
      capture_log(fn ->
        assert "unknown error" == Error.to_string({:error, %{secret: 1}}, :public)
      end)

    assert log =~ "could not generate a public error message for %{secret: 1}"

    log =
      capture_log(fn ->
        assert "unknown error" == Error.to_string([1, 2, 3], :public)
      end)

    assert log =~ "[1, 2, 3]"
  end

  test "public audience renders tagged tuples" do
    assert "(enoent) /etc/hosts" == Error.to_string({:enoent, "/etc/hosts"}, :public)
    assert "(too_many_foos) 123" == Error.to_string({:too_many_foos, 123}, :public)
    assert "(a) (b) (c) :foo" == Error.to_string({:a, {:b, {:c, :foo}}}, :public)
    assert "(EXIT) :killed" == Error.to_string({:EXIT, :killed}, :public)
    assert "(shutdown) :stopped" == Error.to_string({:shutdown, :stopped}, :public)
    assert "(nil) :foo" == Error.to_string({nil, :foo}, :public)
    assert "{:enoent, \"/etc/hosts\"}" == Error.to_string({:enoent, "/etc/hosts"})

    log =
      capture_log(fn ->
        assert "(not_found) unknown error" ==
                 Error.to_string({:not_found, %{id: 1}}, :public)
      end)

    assert log =~ "%{id: 1}"

    log =
      capture_log(fn ->
        assert "unknown error" == Error.to_string({1, 2}, :public)
      end)

    assert log =~ "{1, 2}"
  end

  test "public audience drops the exception banner" do
    {err, stack} =
      try do
        raise ArgumentError, "the message"
      rescue
        e -> {e, __STACKTRACE__}
      end

    assert "** (ArgumentError) the message" == Error.to_string({err, stack})
    assert "the message" == Error.to_string({err, stack}, :public)
  end
end
