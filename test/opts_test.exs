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
      assert_raise Opts.Error,
                   "invalid value for option :cast, expected a boolean, got: :yes",
                   fn -> Opts.validate!([cast: :yes], @defaults, &validate_opt/2) end
    end

    test "raises on unknown option" do
      assert_raise Opts.Error, "unknown option :bogus", fn ->
        Opts.validate!([bogus: 1], @defaults, &validate_opt/2)
      end
    end

    test "raises on duplicate option even when present in defaults" do
      assert_raise Opts.Error, "duplicate option :cast", fn ->
        Opts.validate!([cast: true, cast: false], @defaults, &validate_opt/2)
      end
    end

    test "raises on non tuple element" do
      assert_raise Opts.Error,
                   "expected options to be a keyword list or a map, got: [:cast]",
                   fn ->
                     Opts.validate!([:cast], @defaults, &validate_opt/2)
                   end
    end

    test "raises on non atom key" do
      assert_raise Opts.Error,
                   ~s(expected options in subj to be a keyword list or a map, got: [{"cast", true}]),
                   fn ->
                     Opts.validate!(
                       [{"cast", true}],
                       @defaults,
                       [subject: "subj"],
                       &validate_opt/2
                     )
                   end
    end

    test "raises on improper list with the whole options" do
      assert_raise Opts.Error,
                   "expected options to be a keyword list or a map, got: [{:cast, true} | :sort]",
                   fn ->
                     Opts.validate!([{:cast, true} | :sort], @defaults, &validate_opt/2)
                   end
    end

    test "raises on invalid validator return value" do
      for bad <- [:ok, {:error, :a, :b}, true] do
        assert_raise ArgumentError,
                     "invalid validator return value for option :cast in subj, " <>
                       "expected {:ok, value}, {:error, reason} or :unknown, " <>
                       "got: #{inspect(bad)}",
                     fn ->
                       Opts.validate!([cast: true], @defaults, [subject: "subj"], fn _,
                                                                                     _ ->
                         bad
                       end)
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
      assert_raise Opts.Error,
                   "invalid value for option :cast, expected a boolean, got: :yes",
                   fn -> Opts.validate!(%{cast: :yes}, @defaults, &validate_opt/2) end
    end

    test "raises on non atom key in map options" do
      assert_raise Opts.Error,
                   ~s(expected options to be a keyword list or a map, got: %{"cast" => true}),
                   fn ->
                     Opts.validate!(%{"cast" => true}, @defaults, &validate_opt/2)
                   end
    end

    test "raises on struct options" do
      assert_raise Opts.Error,
                   "expected options to be a keyword list or a map, got: ~D[2026-01-01]",
                   fn ->
                     Opts.validate!(~D[2026-01-01], @defaults, &validate_opt/2)
                   end
    end

    test "raises on options that are neither a list nor a map" do
      assert_raise Opts.Error,
                   "expected options in subj to be a keyword list or a map, got: {:cast, true}",
                   fn ->
                     Opts.validate!(
                       {:cast, true},
                       @defaults,
                       [subject: "subj"],
                       &validate_opt/2
                     )
                   end
    end

    test "includes the subject in messages" do
      assert_raise Opts.Error,
                   "invalid value for option :sort in MyMod.run/2, expected one of :asc, :desc, got: :up",
                   fn ->
                     Opts.validate!(
                       [sort: :up],
                       @defaults,
                       [subject: "MyMod.run/2"],
                       &validate_opt/2
                     )
                   end

      assert_raise Opts.Error, "unknown option :bogus in MyMod.run/2", fn ->
        Opts.validate!([bogus: 1], @defaults, [subject: "MyMod.run/2"], &validate_opt/2)
      end
    end
  end

  describe "validate/3,4" do
    test "returns ok tuple" do
      assert {:ok, %{cast: false, sort: :asc}} =
               Opts.validate([cast: false], @defaults, &validate_opt/2)
    end

    test "returns an Ark.Opts.Error with the kind, path, value, reason and subject" do
      assert {:error,
              %Opts.Error{
                kind: :invalid_value,
                path: [:cast],
                value: :yes,
                reason: "a boolean",
                subject: "subj"
              }} =
               Opts.validate([cast: :yes], @defaults, [subject: "subj"], &validate_opt/2)

      assert {:error, %Opts.Error{kind: :unknown_option, path: [:bogus], subject: nil}} =
               Opts.validate([bogus: 1], @defaults, &validate_opt/2)

      assert {:error, %Opts.Error{kind: :duplicate_option, path: [:cast]}} =
               Opts.validate([cast: true, cast: true], @defaults, &validate_opt/2)

      assert {:error, %Opts.Error{kind: :invalid_options, path: [], value: [:cast]}} =
               Opts.validate([:cast], @defaults, &validate_opt/2)
    end

    test "stops at the first error" do
      assert {:error, %Opts.Error{kind: :unknown_option, path: [:bogus]}} =
               Opts.validate([bogus: 1, cast: :nope], @defaults, &validate_opt/2)
    end

    test "accepts the subject as an option, any term printed with inspect" do
      assert {:error, %Opts.Error{subject: {MyMod, :run}} = e} =
               Opts.validate(
                 [bogus: 1],
                 @defaults,
                 [subject: {MyMod, :run}],
                 &validate_opt/2
               )

      assert "unknown option :bogus in {MyMod, :run}" == Exception.message(e)
    end
  end

  describe "required options" do
    test "are accepted when given" do
      assert %{count: 1} =
               Opts.validate!([count: 1], %{}, [required: [:count]], &validate_opt/2)
    end

    test "are an error when missing, also when present in defaults" do
      assert_raise Opts.Error, "missing required option :count in subj", fn ->
        Opts.validate!(
          [],
          %{count: 1},
          [subject: "subj", required: [:count]],
          &validate_opt/2
        )
      end
    end

    test "are checked after the given options" do
      assert {:error, %Opts.Error{kind: :invalid_value, path: [:cast]}} =
               Opts.validate([cast: :yes], %{}, [required: [:count]], &validate_opt/2)
    end
  end

  describe "error reasons" do
    defp reason_message(reason) do
      {:error, e} = Opts.validate([cast: true], %{}, fn :cast, _ -> {:error, reason} end)
      assert reason == e.reason
      Exception.message(e)
    end

    test "other than strings are kept and formatted in the message" do
      assert "invalid value for option :cast: bad" == reason_message(:bad)
      assert "invalid value for option :cast: 12" == reason_message(12)

      assert "invalid value for option :cast: oops" ==
               reason_message(%RuntimeError{message: "oops"})

      assert "invalid value for option :cast: {:bad, 1}" == reason_message({:bad, 1})
      assert "invalid value for option :cast: [1, 2]" == reason_message([1, 2])
      assert "invalid value for option :cast: nil" == reason_message(nil)
      assert "invalid value for option :cast: false" == reason_message(false)

      assert "invalid value for option :cast: {:any_of, :bad}" ==
               reason_message({:any_of, :bad})
    end
  end

  describe "nested validations" do
    defp validate_nested(opts) do
      Opts.validate(opts, %{}, [subject: "subj"], fn
        :pool, pool ->
          Opts.validate(pool, %{}, [subject: "inner"], fn
            :size, size -> Opts.pos_integer(size)
            :hosts, hosts -> Opts.list_of(hosts, &validate_host/1)
            _, _ -> :unknown
          end)

        _, _ ->
          :unknown
      end)
    end

    defp validate_host(host) do
      Opts.validate(host, %{}, fn
        :name, name -> Opts.string(name)
        _, _ -> :unknown
      end)
    end

    test "prepend the enclosing key to the error path, with the outer subject" do
      assert {:error,
              %Opts.Error{kind: :invalid_value, path: [:pool, :size], value: 0} = e} =
               validate_nested(pool: [size: 0])

      assert "invalid value for option :pool/:size in subj, expected a positive integer, got: 0" ==
               Exception.message(e)

      assert {:error, %Opts.Error{kind: :unknown_option, path: [:pool, :other]}} =
               validate_nested(pool: [other: 1])
    end

    test "locate invalid nested options" do
      assert {:error, %Opts.Error{kind: :invalid_options, path: [:pool]} = e} =
               validate_nested(pool: :none)

      assert "expected option :pool in subj to be a keyword list or a map, got: :none" ==
               Exception.message(e)
    end

    test "keep the inner subject when the outer validation has none" do
      assert {:error, %Opts.Error{subject: "inner", path: [:pool, :size]}} =
               Opts.validate([pool: [size: 0]], %{}, fn :pool, pool ->
                 Opts.validate(pool, %{}, [subject: "inner"], fn :size, v ->
                   Opts.pos_integer(v)
                 end)
               end)
    end

    test "in list_of prepend the index of the element" do
      assert {:error, %Opts.Error{path: [:pool, :hosts, 1, :name], value: :b} = e} =
               validate_nested(pool: [hosts: [[name: "a"], [name: :b]]])

      assert "invalid value for option :pool/:hosts/1/:name in subj, expected a string, got: :b" ==
               Exception.message(e)
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

    test "all_of" do
      non_empty = fn
        [] -> {:error, "a non-empty list"}
        list -> {:ok, list}
      end

      validators = [Opts.list_of(&Opts.atom/1), non_empty]
      assert {:ok, [:a]} = Opts.all_of([:a], validators)
      assert {:error, "a list"} = Opts.all_of(:a, validators)
      assert {:error, "a non-empty list"} = Opts.all_of([], validators)
    end

    test "all_of passes the value returned by each validator to the next one" do
      validator =
        Opts.all_of([
          &Opts.string/1,
          &{:ok, String.upcase(&1)},
          &Opts.member_of(&1, ["A"])
        ])

      assert {:ok, "A"} = validator.("a")
      assert {:error, "one of \"A\""} = validator.("b")
      assert {:error, "a string"} = validator.(:a)
    end

    test "nullable returns reasons other than strings as they are" do
      assert {:error, :bad} = Opts.nullable(1, fn _ -> {:error, :bad} end)
    end

    test "any_of returns {:any_of, reasons} when a reason is not a string" do
      validators = [&Opts.boolean/1, fn _ -> {:error, :bad} end]

      assert {:error, {:any_of, ["a boolean", :bad]} = reason} =
               Opts.any_of(1, validators)

      {:error, e} = Opts.validate([cast: 1], %{}, fn :cast, _ -> {:error, reason} end)
      assert "invalid value for option :cast: a boolean or bad" == Exception.message(e)
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

      assert_raise Opts.Error,
                   ~s(invalid value for option :formats, expected a boolean or a list where each element is an atom, got: ["x"]),
                   fn -> Opts.validate!([formats: ["x"]], %{}, &validate_opt/2) end
    end
  end
end
