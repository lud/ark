if Code.ensure_loaded?(Ecto.Query) do
  defmodule Ark.EctoCursor.Page do
    @moduledoc """
    A page of rows returned by `Ark.EctoCursor.fetch_page/4`.

    * `:entries` - The rows of the page, in the cursor order.
    * `:has_next_page` - `true` when more rows follow the page.
    * `:next_cursor` - The cursor to fetch the following page. It points after
      the last entry, and is the cursor that fetched the page when the page is
      empty. On the last page, it can be kept to fetch rows added later.
    """
    @enforce_keys [:entries, :has_next_page, :next_cursor]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            entries: [map],
            has_next_page: boolean,
            next_cursor: Ark.EctoCursor.t()
          }
  end
end
