if Code.ensure_loaded?(Ecto.Query) do
  defmodule Ark.EctoCursor.MismatchError do
    @moduledoc """
    Returned or raised when a stored cursor is resumed with a different sort
    order.

    The `:stored` field holds the sort order of the stored cursor, and the
    `:expected` field the sort order given to `Ark.EctoCursor.resume/2` or
    `Ark.EctoCursor.resume!/2`, both as lists of `{direction, field}` tuples.
    """
    defexception [:expected, :stored]

    @type t :: %__MODULE__{}

    @impl true
    def message(%{expected: expected, stored: stored}) do
      "stored cursor order_by #{inspect(stored)} does not match expected order_by #{inspect(expected)}"
    end
  end
end
