defmodule Haven.Repo do
  use Ecto.Repo,
    otp_app: :haven,
    adapter: Ecto.Adapters.SQLite3
end
