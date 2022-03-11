defmodule Ark.Interface do
  defmacro definterface(proto, do: block) do
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
