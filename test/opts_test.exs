defmodule Ark.OptsTest do
  use ExUnit.Case, async: true
  alias Ark.Opts

  doctest Ark.Opts

  defp validate_opt(:cast, value) do
    Opts.boolean(value)
  end

  defp validate_opt(:name, value) do
    Opts.nullable(value, &Opts.string/1)
  end

  defp validate_opt(:count, value) do
    Opts.non_neg_integer(value)
  end

  defp validate_opt(:sort, value) do
    Opts.member_of(value, [:asc, :desc])
  end

  defp validate_opt(:formats, value) do
    Opts.any_of(value, [&Opts.boolean/1, Opts.list_of(&Opts.atom/1)])
  end

  defp validate_opt(:upcase, value) do
    value |> Opts.string() |> then_upcase()
  end

  defp validate_opt(_, _) do
    :unknown
  end

  defp then_upcase({:ok, value}) do
    {:ok, String.upcase(value)}
  end

  defp then_upcase(error) do
    error
  end

  @defaults %{cast: true, sort: :asc}

  describe "validate!/3,4" do
    test "merges given options over defaults" do
      assert %{cast: false, sort: :asc, count: 3} ==
               Opts.validate!([cast: false, count: 3], @defaults, &validate_opt/2)
    end

    test "returns defaults for empty options" do
      assert @defaults == Opts.validate!([], @defaults, &validate_opt/2)
    end

    test "stores the value returned by the validator" do
      assert %{upcase: "HELLO"} == Opts.validate!([upcase: "hello"], %{}, &validate_opt/2)
    end

    test "raises on invalid value" do
      assert_raise ArgumentError,
                   "invalid value for option :cast, expected a boolean, got: :yes",
                   fn -> Opts.validate!([cast: :yes], @defaults, &validate_opt/2) end
    end

    test "raises on unknown option" do
      assert_raise ArgumentError, "unknown option :bogus", fn ->
        Opts.validate!([bogus: 1], @defaults, &validate_opt/2)
      end
    end

    test "raises on duplicate option even when present in defaults" do
      assert_raise ArgumentError, "duplicate option :cast", fn ->
        Opts.validate!([cast: true, cast: false], @defaults, &validate_opt/2)
      end
    end

    test "raises on non tuple element" do
      assert_raise ArgumentError,
                   "expected options to be a keyword list or a map, got: [:cast]",
                   fn ->
                     Opts.validate!([:cast], @defaults, &validate_opt/2)
                   end
    end

    test "raises on non atom key" do
      assert_raise ArgumentError,
                   ~s(expected options in subj to be a keyword list or a map, got: [{"cast", true}]),
                   fn ->
                     Opts.validate!([{"cast", true}], @defaults, "subj", &validate_opt/2)
                   end
    end

    test "raises on improper list with the whole options" do
      assert_raise ArgumentError,
                   "expected options to be a keyword list or a map, got: [{:cast, true} | :sort]",
                   fn ->
                     Opts.validate!([{:cast, true} | :sort], @defaults, &validate_opt/2)
                   end
    end

    test "raises on invalid validator return value" do
      for bad <- [:ok, {:error, :bad}, true] do
        assert_raise ArgumentError,
                     "invalid validator return value for option :cast in subj, " <>
                       "expected {:ok, value}, {:error, expected} with a string, or :unknown, " <>
                       "got: #{inspect(bad)}",
                     fn ->
                       Opts.validate!([cast: true], @defaults, "subj", fn _, _ -> bad end)
                     end
      end
    end

    test "invalid validator return value raises from validate/4" do
      assert_raise ArgumentError, ~r/invalid validator return value/, fn ->
        Opts.validate([cast: true], @defaults, fn _, _ -> :ok end)
      end
    end

    test "accepts map options" do
      assert %{cast: false, sort: :asc, count: 3} ==
               Opts.validate!(%{cast: false, count: 3}, @defaults, &validate_opt/2)
    end

    test "raises on invalid value in map options" do
      assert_raise ArgumentError,
                   "invalid value for option :cast, expected a boolean, got: :yes",
                   fn -> Opts.validate!(%{cast: :yes}, @defaults, &validate_opt/2) end
    end

    test "raises on non atom key in map options" do
      assert_raise ArgumentError,
                   ~s(expected options to be a keyword list or a map, got: %{"cast" => true}),
                   fn ->
                     Opts.validate!(%{"cast" => true}, @defaults, &validate_opt/2)
                   end
    end

    test "raises on struct options" do
      assert_raise ArgumentError,
                   "expected options to be a keyword list or a map, got: ~D[2026-01-01]",
                   fn ->
                     Opts.validate!(~D[2026-01-01], @defaults, &validate_opt/2)
                   end
    end

    test "raises on options that are neither a list nor a map" do
      assert_raise ArgumentError,
                   "expected options in subj to be a keyword list or a map, got: {:cast, true}",
                   fn ->
                     Opts.validate!({:cast, true}, @defaults, "subj", &validate_opt/2)
                   end
    end

    test "includes the subject in messages" do
      assert_raise ArgumentError,
                   "invalid value for option :sort in MyMod.run/2, expected one of :asc, :desc, got: :up",
                   fn ->
                     Opts.validate!(
                       [sort: :up],
                       @defaults,
                       "MyMod.run/2",
                       &validate_opt/2
                     )
                   end

      assert_raise ArgumentError, "unknown option :bogus in MyMod.run/2", fn ->
        Opts.validate!([bogus: 1], @defaults, "MyMod.run/2", &validate_opt/2)
      end
    end
  end

  describe "validate/3,4" do
    test "returns ok tuple" do
      assert {:ok, %{cast: false, sort: :asc}} =
               Opts.validate([cast: false], @defaults, &validate_opt/2)
    end

    test "returns an ArgumentError" do
      assert {:error, %ArgumentError{message: "unknown option :bogus in subj"}} =
               Opts.validate([bogus: 1], @defaults, "subj", &validate_opt/2)
    end

    test "stops at the first error" do
      assert {:error, %ArgumentError{message: "unknown option :bogus"}} =
               Opts.validate([bogus: 1, cast: :nope], @defaults, &validate_opt/2)
    end
  end

  describe "value helpers" do
    test "scalar types" do
      assert {:ok, true} = Opts.boolean(true)
      assert {:error, "a boolean"} = Opts.boolean(nil)
      assert {:ok, "s"} = Opts.string("s")
      assert {:error, "a string"} = Opts.string(:s)
      assert {:ok, :a} = Opts.atom(:a)
      assert {:error, "an atom"} = Opts.atom("a")
      assert {:ok, -1} = Opts.integer(-1)
      assert {:error, "an integer"} = Opts.integer(1.0)
      assert {:ok, 0} = Opts.non_neg_integer(0)
      assert {:error, "a non-negative integer"} = Opts.non_neg_integer(-1)
      assert {:ok, 1} = Opts.pos_integer(1)
      assert {:error, "a positive integer"} = Opts.pos_integer(0)
      assert {:ok, 1.5} = Opts.number(1.5)
      assert {:error, "a number"} = Opts.number("1")
      assert {:ok, %{}} = Opts.map(%{})
      assert {:error, "a map"} = Opts.map([])
      assert {:ok, [a: 1]} = Opts.keyword_list(a: 1)
      assert {:error, "a keyword list"} = Opts.keyword_list([1])
    end

    test "function and mfa" do
      f = fn x -> x end
      assert {:ok, ^f} = Opts.function(f, 1)
      assert {:error, "a function of arity 2"} = Opts.function(f, 2)
      assert {:ok, {M, :f, []}} = Opts.mfa({M, :f, []})
      assert {:error, "a {module, function, args} tuple"} = Opts.mfa({M, :f})
    end

    test "member_of" do
      assert {:ok, :a} = Opts.member_of(:a, [:a, :b])
      assert {:error, "one of :a, :b"} = Opts.member_of(:c, [:a, :b])
    end
  end

  describe "combinators" do
    test "nullable" do
      assert {:ok, nil} = Opts.nullable(nil, &Opts.string/1)
      assert {:ok, "s"} = Opts.nullable("s", &Opts.string/1)
      assert {:error, "a string or nil"} = Opts.nullable(1, &Opts.string/1)
    end

    test "any_of" do
      validators = [&Opts.boolean/1, Opts.list_of(&Opts.atom/1)]
      assert {:ok, true} = Opts.any_of(true, validators)
      assert {:ok, [:a]} = Opts.any_of([:a], validators)
      assert {:error, "a boolean or a list"} = Opts.any_of(1, validators)

      assert {:error, "a boolean or a list where each element is an atom"} =
               Opts.any_of(["a"], validators)
    end

    test "list_of" do
      assert {:ok, []} = Opts.list_of([], &Opts.atom/1)
      assert {:ok, [:a, :b]} = Opts.list_of([:a, :b], &Opts.atom/1)

      assert {:error, "a list where each element is an atom"} =
               Opts.list_of([:a, "b"], &Opts.atom/1)

      assert {:error, "a list"} = Opts.list_of(:a, &Opts.atom/1)
      assert {:error, "a proper list"} = Opts.list_of([:a | :b], &Opts.atom/1)
    end

    test "arity-1 forms return composable validators" do
      validator =
        Opts.list_of(
          Opts.nullable(Opts.any_of([Opts.member_of([:a, :b]), &Opts.integer/1]))
        )

      assert {:ok, [:a, nil, 1]} = validator.([:a, nil, 1])

      assert {:error, "a list where each element is one of :a, :b or an integer or nil"} =
               validator.([:c])
    end

    test "list_of keeps values returned by the element validator" do
      upcase = fn v -> v |> Opts.string() |> then_upcase() end
      assert {:ok, ["A", "B"]} = Opts.list_of(["a", "b"], upcase)
    end

    test "composed through validate!" do
      assert %{formats: [:a]} = Opts.validate!([formats: [:a]], %{}, &validate_opt/2)
      assert %{name: nil} = Opts.validate!([name: nil], %{}, &validate_opt/2)

      assert_raise ArgumentError,
                   ~s(invalid value for option :formats, expected a boolean or a list where each element is an atom, got: ["x"]),
                   fn -> Opts.validate!([formats: ["x"]], %{}, &validate_opt/2) end
    end
  end
end
