defmodule Ark.TestRepo do
  use Ecto.Repo, otp_app: :ark, adapter: Ecto.Adapters.SQLite3
end
