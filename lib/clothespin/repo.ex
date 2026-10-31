defmodule Clothespin.Repo do
  use Ecto.Repo,
    otp_app: :clothespin,
    adapter: Ecto.Adapters.Postgres
end
