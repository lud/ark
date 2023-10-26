defmodule Ark.BinarySearchTest do
  alias Ark.BinarySearch
  use ExUnit.Case, async: true

  def answer(x) do
    fn
      ^x -> :eq
      n when n < x -> :lt
      n when n > x -> :gt
    end
  end

  test "basic tests" do
    assert 1 = BinarySearch.search(answer(1))
    assert -1 = BinarySearch.search(answer(-1))
    assert 0 = BinarySearch.search(answer(0))
    assert 10 = BinarySearch.search(answer(10))
    assert -10 = BinarySearch.search(answer(-10))

    Enum.each(1..10000, fn n ->
      assert n == BinarySearch.search(answer(n))
    end)

    Enum.each(1..10000, fn _ ->
      n = Enum.random(-999_999_999_999_999_999..+999_999_999_999_999_999)
      assert n == BinarySearch.search(answer(n))
    end)
  end

  test "large numbers" do
    assert 1_234_456_789_100_277_636 =
             BinarySearch.search(answer(1_234_456_789_100_277_636))

    assert -1_234_456_789_100_277_636 =
             BinarySearch.search(answer(-1_234_456_789_100_277_636))
  end

  test "prime numbers" do
    assert 9_007_199_254_740_881 = BinarySearch.search(answer(9_007_199_254_740_881))
    assert -9_007_199_254_740_881 = BinarySearch.search(answer(-9_007_199_254_740_881))
  end
end
