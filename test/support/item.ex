defmodule Ark.TestItem do
  use Ecto.Schema

  schema "items" do
    field(:uuid, Ecto.UUID)
    field(:name, :string)
    field(:score, :integer)
    field(:created_at, :naive_datetime)
  end
end
