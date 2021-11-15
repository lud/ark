defmodule Ark.StructAccessTest do
  use ExUnit.Case, async: true
  doctest Ark.StructAccess

  defmodule TestMod do
    use Ark.StructAccess
    defstruct a: 1, b: 2, sub: nil
  end

  defmodule TestModSub do
    use Ark.StructAccess
    defstruct x: 1, y: 2
  end

  test "struct access" do
    s = %TestMod{a: 1, b: 2}
    assert 1 = get_in(s, [:a])
    assert %TestMod{a: 1, b: 999} = put_in(s.b, 999)
  end

  test "nested struct access" do
    s = %TestMod{a: 1, b: 2, sub: %TestModSub{x: 10}}
    assert %TestMod{sub: %TestModSub{x: 20}} = put_in(s.sub.x, 20)
  end
end
