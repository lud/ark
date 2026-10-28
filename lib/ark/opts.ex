defmodule Ark.Opts do
  @moduledoc ~S"""
  Validates options with a callback and merges them over defaults.

  `validate!/3` calls the validator callback with the key and value of each
  given option. The callback checks the value, usually with one of the helpers
  of this module, and returns `{:ok, value}`. The result is a map of the
  defaults, overridden by the given options.

      iex> Ark.Opts.validate!([timeout: 500], %{timeout: 5000, retry: true}, fn
      ...>   :timeout, value -> Ark.Opts.pos_integer(value)
      ...>   :retry, value -> Ark.Opts.boolean(value)
      ...>   _, _ -> :unknown
      ...> end)
      %{timeout: 500, retry: true}

  `validate/3` returns the error as an `ArgumentError` instead of raising it.
  The message names the option, the expected value and the given value.

      iex> Ark.Opts.validate([timeout: 0], %{timeout: 5000}, fn
      ...>   :timeout, value -> Ark.Opts.pos_integer(value)
      ...>   _, _ -> :unknown
      ...> end)
      {:error, %ArgumentError{message: "invalid value for option :timeout, expected a positive integer, got: 0"}}

  The options are a keyword list or a map with atom keys.

      iex> Ark.Opts.validate!(%{timeout: 500}, %{timeout: 5000, retry: true}, fn
      ...>   :timeout, value -> Ark.Opts.pos_integer(value)
      ...>   :retry, value -> Ark.Opts.boolean(value)
      ...>   _, _ -> :unknown
      ...> end)
      %{timeout: 500, retry: true}

  ### Validator callback

  The callback receives the option key and the option value, and returns one
  of:

  * `{:ok, value}` - The option is valid. The returned value is stored in the
    result, so the callback can also normalize the value.
  * `{:error, expected}` - The option is invalid. `expected` is a string
    describing the accepted values, such as `"a positive integer"`, which reads
    after "expected" in the error message.
  * `:unknown` - The key is not a supported option.

  Validation stops at the first error. Options in a keyword list are validated
  in the order they are given, and a key given twice is also an error. The
  defaults are merged as they are, so they hold values in their final form.

  In a module, a named function with one clause per option is a convenient
  validator. The optional subject argument names the caller in error messages.

      defmodule MyApp.Client do
        @defaults %{timeout: 5000, retries: 3}

        def get(url, opts \\ []) do
          %{timeout: timeout, retries: retries} =
            Ark.Opts.validate!(opts, @defaults, "MyApp.Client.get/2", &validate_opt/2)

          MyApp.HTTP.get(url, timeout: timeout, retries: retries)
        end

        defp validate_opt(:timeout, value) do
          Ark.Opts.any_of(value, [&Ark.Opts.pos_integer/1, Ark.Opts.member_of([:infinity])])
        end

        defp validate_opt(:retries, value) do
          Ark.Opts.non_neg_integer(value)
        end

        defp validate_opt(_, _) do
          :unknown
        end
      end

  Calling `MyApp.Client.get("/", retries: -1)` raises the same error as this
  direct call, with the subject in the message.

      iex> Ark.Opts.validate!([retries: -1], %{retries: 3}, "MyApp.Client.get/2", fn
      ...>   :retries, value -> Ark.Opts.non_neg_integer(value)
      ...>   _, _ -> :unknown
      ...> end)
      ** (ArgumentError) invalid value for option :retries in MyApp.Client.get/2, expected a non-negative integer, got: -1

  ### Value helpers

  The value helpers, such as `string/1` or `pos_integer/1`, take a value and
  return `{:ok, value}` or `{:error, expected}`, so a callback clause can return
  their result directly. `member_of/2` accepts the values of a given list.

  The combinators `any_of/2`, `all_of/2`, `nullable/2` and `list_of/2` check a
  value with other validators. Their arity 1 variants, like `member_of/1`, return a
  validator function, so they compose into nested validators.

      iex> validator =
      ...>   Ark.Opts.list_of(Ark.Opts.any_of([Ark.Opts.member_of([:asc, :desc]), &Ark.Opts.string/1]))
      iex> validator.([:asc, "name"])
      {:ok, [:asc, "name"]}
      iex> validator.([:asc, 1])
      {:error, "a list where each element is one of :asc, :desc or a string"}

  A custom clause can accept several forms of a value and return a normalized
  one.

      iex> Ark.Opts.validate!([tags: "a,b"], %{tags: []}, fn
      ...>   :tags, value when is_binary(value) -> {:ok, String.split(value, ",")}
      ...>   :tags, value -> Ark.Opts.list_of(value, &Ark.Opts.string/1)
      ...>   _, _ -> :unknown
      ...> end)
      %{tags: ["a", "b"]}
  """

  @doc false
  def __ark__(:doc) do
    """
    This module validates options, given as a keyword list or a map, with a
    callback and merges them over defaults, with helpers to check the option
    values.

    ```elixir
    Ark.Opts.validate!([timeout: 500], %{timeout: 5000, retry: true}, fn
      :timeout, value -> Ark.Opts.pos_integer(value)
      :retry, value -> Ark.Opts.boolean(value)
      _, _ -> :unknown
    end)

    # => %{timeout: 500, retry: true}
    ```
    """
  end

  @type expected :: String.t()
  @type result :: {:ok, term} | {:error, expected}
  @type validator :: (atom, term -> result | :unknown)
  @type subject :: String.t() | nil

  @doc """
  Same as `validate/4`, but returns the options map directly and raises the
  `ArgumentError` on invalid options.

      iex> Ark.Opts.validate!([level: :debug], %{level: :info}, "MyApp.log/2", fn
      ...>   :level, value -> Ark.Opts.member_of(value, [:debug, :info, :error])
      ...>   _, _ -> :unknown
      ...> end)
      %{level: :debug}
  """
  @spec validate!(term, map, validator) :: map
  @spec validate!(term, map, subject, validator) :: map
  def validate!(opts, defaults, subject \\ nil, fun) do
    case validate(opts, defaults, subject, fun) do
      {:ok, map} -> map
      {:error, e} -> raise e
    end
  end

  @doc """
  Validates `opts` with the `fun` callback and merges the validated options
  over `defaults`.

      iex> Ark.Opts.validate([level: :debug], %{level: :info}, "MyApp.log/2", fn
      ...>   :level, value -> Ark.Opts.member_of(value, [:debug, :info, :error])
      ...>   _, _ -> :unknown
      ...> end)
      {:ok, %{level: :debug}}

  The arguments are:

  * `opts` - The options to validate, a keyword list or a map with atom keys.
  * `defaults` - A map of values for the options that are not given.
  * `subject` - An optional string naming the caller, such as
    `"MyApp.log/2"`, included in error messages.
  * `fun` - The validator callback, a function of arity 2 called with the key
    and the value of each option. See the "Validator callback" section of the
    module documentation for its return values.

  Returns `{:ok, map}` with the defaults and the values returned by the
  callback. Returns `{:error, %ArgumentError{}}` when `opts` is a struct or is
  not a keyword list or a map with atom keys, when an option is given twice, or
  when the callback returns `{:error, expected}` or `:unknown`.

      iex> Ark.Opts.validate([color: :red], %{}, "MyApp.log/2", fn _, _ -> :unknown end)
      {:error, %ArgumentError{message: "unknown option :color in MyApp.log/2"}}

  Raises an `ArgumentError` when the callback returns another value.
  """
  @spec validate(term, map, validator) :: {:ok, map} | {:error, Exception.t()}
  @spec validate(term, map, subject, validator) ::
          {:ok, map} | {:error, Exception.t()}
  def validate(opts, defaults, subject \\ nil, fun)
      when is_map(defaults) and (is_binary(subject) or is_nil(subject)) and
             is_function(fun, 2) do
    case reduce(to_list(opts), %{}, subject, fun) do
      {:ok, given} -> {:ok, Map.merge(defaults, given)}
      {:error, message} -> {:error, ArgumentError.exception(message)}
    end
  catch
    :throw, {__MODULE__, :invalid_shape} ->
      {:error,
       ArgumentError.exception(
         "expected options#{in_subject(subject)} to be a keyword list or a map, " <>
           "got: #{inspect(opts)}"
       )}
  end

  defp to_list(opts) when is_list(opts) do
    opts
  end

  defp to_list(opts) when is_map(opts) and not is_struct(opts) do
    Map.to_list(opts)
  end

  defp to_list(_opts) do
    throw({__MODULE__, :invalid_shape})
  end

  defp reduce([], acc, _subject, _fun) do
    {:ok, acc}
  end

  defp reduce([{key, _} | _], acc, subject, _fun) when is_map_key(acc, key) do
    {:error, "duplicate option #{inspect(key)}#{in_subject(subject)}"}
  end

  defp reduce([{key, value} | rest], acc, subject, fun) when is_atom(key) do
    case fun.(key, value) do
      {:ok, value} ->
        reduce(rest, Map.put(acc, key, value), subject, fun)

      {:error, expected} when is_binary(expected) ->
        {:error,
         "invalid value for option #{inspect(key)}#{in_subject(subject)}, " <>
           "expected #{expected}, got: #{inspect(value)}"}

      :unknown ->
        {:error, "unknown option #{inspect(key)}#{in_subject(subject)}"}

      other ->
        raise ArgumentError,
              "invalid validator return value for option #{inspect(key)}#{in_subject(subject)}, " <>
                "expected {:ok, value}, {:error, expected} with a string, or :unknown, " <>
                "got: #{inspect(other)}"
    end
  end

  defp reduce(_invalid, _acc, _subject, _fun) do
    throw({__MODULE__, :invalid_shape})
  end

  defp in_subject(nil) do
    ""
  end

  defp in_subject(subject) do
    " in " <> subject
  end

  @doc """
  Validates that `value` is a boolean.

      iex> Ark.Opts.boolean(true)
      {:ok, true}
      iex> Ark.Opts.boolean(nil)
      {:error, "a boolean"}
  """
  @spec boolean(term) :: result
  def boolean(value) when is_boolean(value) do
    {:ok, value}
  end

  def boolean(_) do
    {:error, "a boolean"}
  end

  @doc """
  Validates that `value` is a string.

      iex> Ark.Opts.string("hello")
      {:ok, "hello"}
      iex> Ark.Opts.string(:hello)
      {:error, "a string"}
  """
  @spec string(term) :: result
  def string(value) when is_binary(value) do
    {:ok, value}
  end

  def string(_) do
    {:error, "a string"}
  end

  @doc """
  Validates that `value` is an atom.

      iex> Ark.Opts.atom(:hello)
      {:ok, :hello}
      iex> Ark.Opts.atom("hello")
      {:error, "an atom"}
  """
  @spec atom(term) :: result
  def atom(value) when is_atom(value) do
    {:ok, value}
  end

  def atom(_) do
    {:error, "an atom"}
  end

  @doc """
  Validates that `value` is an integer.

      iex> Ark.Opts.integer(-1)
      {:ok, -1}
      iex> Ark.Opts.integer(1.0)
      {:error, "an integer"}
  """
  @spec integer(term) :: result
  def integer(value) when is_integer(value) do
    {:ok, value}
  end

  def integer(_) do
    {:error, "an integer"}
  end

  @doc """
  Validates that `value` is an integer greater than or equal to zero.

      iex> Ark.Opts.non_neg_integer(0)
      {:ok, 0}
      iex> Ark.Opts.non_neg_integer(-1)
      {:error, "a non-negative integer"}
  """
  @spec non_neg_integer(term) :: result
  def non_neg_integer(value) when is_integer(value) and value >= 0 do
    {:ok, value}
  end

  def non_neg_integer(_) do
    {:error, "a non-negative integer"}
  end

  @doc """
  Validates that `value` is an integer greater than zero.

      iex> Ark.Opts.pos_integer(1)
      {:ok, 1}
      iex> Ark.Opts.pos_integer(0)
      {:error, "a positive integer"}
  """
  @spec pos_integer(term) :: result
  def pos_integer(value) when is_integer(value) and value > 0 do
    {:ok, value}
  end

  def pos_integer(_) do
    {:error, "a positive integer"}
  end

  @doc """
  Validates that `value` is an integer or a float.

      iex> Ark.Opts.number(1.5)
      {:ok, 1.5}
      iex> Ark.Opts.number("1.5")
      {:error, "a number"}
  """
  @spec number(term) :: result
  def number(value) when is_number(value) do
    {:ok, value}
  end

  def number(_) do
    {:error, "a number"}
  end

  @doc """
  Validates that `value` is a map.

      iex> Ark.Opts.map(%{a: 1})
      {:ok, %{a: 1}}
      iex> Ark.Opts.map([a: 1])
      {:error, "a map"}
  """
  @spec map(term) :: result
  def map(value) when is_map(value) do
    {:ok, value}
  end

  def map(_) do
    {:error, "a map"}
  end

  @doc """
  Validates that `value` is a keyword list.

      iex> Ark.Opts.keyword_list([a: 1])
      {:ok, [a: 1]}
      iex> Ark.Opts.keyword_list(%{a: 1})
      {:error, "a keyword list"}
  """
  @spec keyword_list(term) :: result
  def keyword_list(value) do
    if Keyword.keyword?(value) do
      {:ok, value}
    else
      {:error, "a keyword list"}
    end
  end

  @doc """
  Validates that `value` is a function of the given `arity`.

      iex> fun = fn x -> x end
      iex> {:ok, ^fun} = Ark.Opts.function(fun, 1)
      iex> Ark.Opts.function(fun, 2)
      {:error, "a function of arity 2"}
  """
  @spec function(term, arity) :: result
  def function(value, arity) when is_function(value, arity) do
    {:ok, value}
  end

  def function(_, arity) do
    {:error, "a function of arity #{arity}"}
  end

  @doc """
  Validates that `value` is a `{module, function, args}` tuple, where `args` is a list.

      iex> Ark.Opts.mfa({MyApp.Handler, :handle, [:extra]})
      {:ok, {MyApp.Handler, :handle, [:extra]}}
      iex> Ark.Opts.mfa({MyApp.Handler, :handle})
      {:error, "a {module, function, args} tuple"}
  """
  @spec mfa(term) :: result
  def mfa({m, f, a} = value) when is_atom(m) and is_atom(f) and is_list(a) do
    {:ok, value}
  end

  def mfa(_) do
    {:error, "a {module, function, args} tuple"}
  end

  @doc """
  Returns a validator that accepts the values of the `allowed` list.

  See `member_of/2`.

      iex> validator = Ark.Opts.member_of([:asc, :desc])
      iex> validator.(:asc)
      {:ok, :asc}
  """
  @spec member_of([term]) :: (term -> result)
  def member_of(allowed) do
    &member_of(&1, allowed)
  end

  @doc """
  Validates that `value` is one of the `allowed` values.

      iex> Ark.Opts.member_of(:asc, [:asc, :desc])
      {:ok, :asc}
      iex> Ark.Opts.member_of(:up, [:asc, :desc])
      {:error, "one of :asc, :desc"}
  """
  @spec member_of(term, [term]) :: result
  def member_of(value, allowed) do
    if value in allowed do
      {:ok, value}
    else
      {:error, "one of #{Enum.map_join(allowed, ", ", &inspect/1)}"}
    end
  end

  @doc """
  Returns a validator that accepts `nil` or the values accepted by `validator`.

  See `nullable/2`.

      iex> validator = Ark.Opts.nullable(&Ark.Opts.string/1)
      iex> validator.(nil)
      {:ok, nil}
  """
  @spec nullable((term -> result)) :: (term -> result)
  def nullable(validator) do
    &nullable(&1, validator)
  end

  @doc """
  Validates that `value` is `nil` or a value accepted by `validator`.

      iex> Ark.Opts.nullable(nil, &Ark.Opts.string/1)
      {:ok, nil}
      iex> Ark.Opts.nullable("hello", &Ark.Opts.string/1)
      {:ok, "hello"}
      iex> Ark.Opts.nullable(1, &Ark.Opts.string/1)
      {:error, "a string or nil"}
  """
  @spec nullable(term, (term -> result)) :: result
  def nullable(nil, _validator) do
    {:ok, nil}
  end

  def nullable(value, validator) do
    case validator.(value) do
      {:ok, _} = ok -> ok
      {:error, expected} -> {:error, expected <> " or nil"}
    end
  end

  @doc """
  Returns a validator that accepts the values accepted by any of `validators`.

  See `any_of/2`.

      iex> validator = Ark.Opts.any_of([&Ark.Opts.boolean/1, &Ark.Opts.pos_integer/1])
      iex> validator.(10)
      {:ok, 10}
  """
  @spec any_of([(term -> result), ...]) :: (term -> result)
  def any_of([_ | _] = validators) do
    &any_of(&1, validators)
  end

  @doc """
  Validates `value` with each of `validators` in order, and returns the result
  of the first one that accepts it.

  The `validators` argument is a non-empty list. When no validator accepts the
  value, the error joins all expected descriptions.

      iex> Ark.Opts.any_of(10, [&Ark.Opts.boolean/1, &Ark.Opts.pos_integer/1])
      {:ok, 10}
      iex> Ark.Opts.any_of(-1, [&Ark.Opts.boolean/1, &Ark.Opts.pos_integer/1])
      {:error, "a boolean or a positive integer"}
  """
  @spec any_of(term, [(term -> result), ...]) :: result
  def any_of(value, [_ | _] = validators) do
    any_of(value, validators, [])
  end

  defp any_of(value, [validator | validators], expected_acc) do
    case validator.(value) do
      {:ok, _} = ok -> ok
      {:error, expected} -> any_of(value, validators, [expected | expected_acc])
    end
  end

  defp any_of(_value, [], expected_acc) do
    {:error, expected_acc |> :lists.reverse() |> Enum.join(" or ")}
  end

  @doc """
  Returns a validator that accepts the values accepted by all of `validators`.

  See `all_of/2`.

      iex> validator = Ark.Opts.all_of([&Ark.Opts.string/1, &{:ok, String.trim(&1)}])
      iex> validator.("  hello ")
      {:ok, "hello"}
  """
  @spec all_of([(term -> result), ...]) :: (term -> result)
  def all_of([_ | _] = validators) do
    &all_of(&1, validators)
  end

  @doc """
  Validates `value` with each of `validators` in order, and returns the result
  of the last one.

  The `validators` argument is a non-empty list. Each validator receives the
  value returned by the previous one, so a validator can rely on the checks and
  the normalization done before it. Validation stops at the first error, which
  is returned as is.

      iex> non_empty = fn
      ...>   [] -> {:error, "a non-empty list"}
      ...>   list -> {:ok, list}
      ...> end
      iex> Ark.Opts.all_of([:a], [Ark.Opts.list_of(&Ark.Opts.atom/1), non_empty])
      {:ok, [:a]}
      iex> Ark.Opts.all_of([], [Ark.Opts.list_of(&Ark.Opts.atom/1), non_empty])
      {:error, "a non-empty list"}
      iex> Ark.Opts.all_of(:a, [Ark.Opts.list_of(&Ark.Opts.atom/1), non_empty])
      {:error, "a list"}
  """
  @spec all_of(term, [(term -> result), ...]) :: result
  def all_of(value, [_ | _] = validators) do
    all_of_reduce(value, validators)
  end

  defp all_of_reduce(value, [validator | validators]) do
    case validator.(value) do
      {:ok, value} -> all_of_reduce(value, validators)
      {:error, _} = error -> error
    end
  end

  defp all_of_reduce(value, []) do
    {:ok, value}
  end

  @doc """
  Returns a validator that accepts lists where each element is accepted by
  `validator`.

  See `list_of/2`.

      iex> validator = Ark.Opts.list_of(&Ark.Opts.atom/1)
      iex> validator.([:a, :b])
      {:ok, [:a, :b]}
  """
  @spec list_of((term -> result)) :: (term -> result)
  def list_of(validator) do
    &list_of(&1, validator)
  end

  @doc """
  Validates that `value` is a list and that `validator` accepts each element.

  Returns a list of the values returned by `validator`, in the same order.

      iex> Ark.Opts.list_of([:a, :b], &Ark.Opts.atom/1)
      {:ok, [:a, :b]}
      iex> Ark.Opts.list_of([:a, "b"], &Ark.Opts.atom/1)
      {:error, "a list where each element is an atom"}
      iex> Ark.Opts.list_of(:a, &Ark.Opts.atom/1)
      {:error, "a list"}
  """
  @spec list_of(term, (term -> result)) :: result
  def list_of(value, validator) when is_list(value) do
    list_of(value, validator, [])
  end

  def list_of(_value, _validator) do
    {:error, "a list"}
  end

  defp list_of([item | rest], validator, acc) do
    case validator.(item) do
      {:ok, item} -> list_of(rest, validator, [item | acc])
      {:error, expected} -> {:error, "a list where each element is #{expected}"}
    end
  end

  defp list_of([], _validator, acc) do
    {:ok, :lists.reverse(acc)}
  end

  defp list_of(_improper, _validator, _acc) do
    {:error, "a proper list"}
  end
end
