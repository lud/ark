defmodule Ark.TestCursorHolder do
  use Ecto.Schema

  schema "cursor_holders" do
    embeds_one(:cursor, Ark.EctoCursor, on_replace: :delete)
  end
end
