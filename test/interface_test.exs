import Ark.Interface

definterface P do
  def get_val(t, k)

  def put_val(t, k, v)
end

defmodule Ark.InterfaceTest do
  use ExUnit.Case, async: true

  require Ark.Interface

  Ark.Interface.definterface P do
    def get_val(t, k)

    def put_val(t, k, v)
  end

  defmodule CommonImpl do
    def get_val(%{vars: vars}, k) do
      Map.get(vars, k)
    end

    def put_val(%{vars: vars} = t, k, v) do
      %{t | vars: Map.put(vars, k, v)}
    end
  end

  defmodule Derives do
    @derive P
    defstruct vars: %{}
    def new, do: %__MODULE__{}
    defdelegate get_val(t, k), to: CommonImpl
    defdelegate put_val(t, k, v), to: CommonImpl
  end

  defmodule AutoImplements do
    Ark.Interface.auto_impl(P)
    defstruct vars: %{}
    def new, do: %__MODULE__{}
    defdelegate get_val(t, k), to: CommonImpl
    defdelegate put_val(t, k, v), to: CommonImpl
  end

  test "assert the interfaces creates a protocol" do
    case P.__protocol__(:impls) do
      {:consolidated, _} -> assert true
      :not_consolidated -> assert true
    end
  rescue
    _ ->
      flunk("protocol not implemented")
  end

  test "a protocol can be implemented using deriving" do
    assert 123 =
             Derives.new()
             |> P.put_val(:k1, 123)
             |> P.get_val(:k1)
  end

  test "a protocol can be implemented using auto_impl" do
    assert 123 =
             AutoImplements.new()
             |> P.put_val(:k1, 123)
             |> P.get_val(:k1)
  end
end
