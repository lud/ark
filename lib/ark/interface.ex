defmodule Ark.Interface do
  @moduledoc """
  Defines protocols whose implementation lives as plain functions on the
  implementing struct's own module.

  A regular Elixir protocol needs a separate `defimpl` block for every struct it
  supports. `Ark.Interface` removes that step: you declare the function
  signatures once with `definterface/2`, and a struct satisfies the protocol by
  defining functions of the same name on its module and opting in.

  ### Minimal example

  Declare the interface with the function heads it requires:

      import Ark.Interface

      definterface Movable do
        def move(t, dx, dy)
      end

  Implement it on a struct by defining the matching function and deriving the
  interface:

      defmodule Point do
        @derive Movable
        defstruct [:x, :y]

        def move(%Point{x: x, y: y}, dx, dy) do
          %Point{x: x + dx, y: y + dy}
        end
      end

  Calling the interface dispatches to the struct module's own function:

      Movable.move(%Point{x: 0, y: 0}, 2, 3)
      # => %Point{x: 2, y: 5}

  ### Wiring an implementation

  A struct opts into an interface in one of two ways:

    * Add `@derive TheInterface` next to `defstruct`, and define a function for
      each interface signature on the same module (directly or with
      `defdelegate`).
    * Call `Ark.Interface.auto_impl/1` inside the module body, which builds the
      same delegation without `@derive`.

  Both make `TheInterface.fun(struct, ...)` call `TheModule.fun(struct, ...)`.
  Passing a struct that has opted into neither raises, since the interface has
  no implementation to dispatch to.
  """

  @doc false
  def __ark__(:doc) do
    """
    This module provides a way to define protocols that dispatch to functions
    defined on the implementing struct's own module.
    """
  end

  @doc """
  Declares an interface: a protocol plus the machinery to implement it from a
  struct's own module.

  `proto` is the protocol module to define. The `do` block holds one `def` head
  per interface function, written as a signature with no body, exactly as in
  `defprotocol/2`.

      import Ark.Interface

      definterface Movable do
        def move(t, dx, dy)
      end

  This defines the `Movable` protocol and lets any struct implement it by
  deriving it or by calling `auto_impl/1`. See `Ark.Interface` for how a struct
  is wired to an interface.
  """
  defmacro definterface(proto, [{:do, block}]) do
    {:__block__, _, top_level} = block

    defs =
      Enum.filter(
        top_level,
        &(is_tuple(&1) and tuple_size(&1) == 3 and :def == elem(&1, 0))
      )

    # Generate implementation of the protocol that will throw
    defs_for_any_itself =
      Enum.map(defs, fn {:def, _meta, [{function, _meta2, args}]} ->
        args = Enum.map(args, fn _ -> {:_, [], nil} end)

        quote do
          def unquote(function)(unquote_splicing(args)) do
            raise "#{inspect(unquote(proto))} must be derived"
          end
        end
      end)

    [
      # Define the protocol
      quote location: :keep do
        defprotocol unquote(proto) do
          unquote(block)
        end
      end,

      # Define the implemementation for Any, containing the deriving macro
      quote location: :keep do
        defimpl unquote(proto), for: Any do
          defmacro __deriving__(_module, _struct, _options) do
            proto = unquote(proto)

            quote do
              require Ark.Interface
              Ark.Interface.auto_impl(unquote(proto))
            end
          end

          unquote(defs_for_any_itself)
        end
      end
    ]
  end

  @doc """
  Implements `proto` for the current struct module by delegating to its own
  functions.

  Call this inside a struct module as an alternative to `@derive proto`. For
  each function the interface declares, it generates an implementation that
  calls the function of the same name and arity defined on the current module.

      defmodule Point do
        Ark.Interface.auto_impl(Movable)
        defstruct [:x, :y]

        def move(%Point{x: x, y: y}, dx, dy) do
          %Point{x: x + dx, y: y + dy}
        end
      end

  See `Ark.Interface` for the full picture, including the `@derive` form.
  """
  defmacro auto_impl(proto) do
    module = __CALLER__.module

    quote location: :keep,
          bind_quoted: [
            proto: proto,
            module: module
          ] do
      defs = proto.__protocol__(:functions)

      defimpl proto do
        Enum.each(defs, fn {function, arity} when arity > 0 ->
          args = Enum.map(1..arity//1, fn i -> Macro.var(:"arg_#{i}", :auto_defimpl) end)

          def unquote(function)(unquote_splicing(args)) do
            unquote(module).unquote(function)(unquote_splicing(args))
          end
        end)
      end
    end
  end
end
