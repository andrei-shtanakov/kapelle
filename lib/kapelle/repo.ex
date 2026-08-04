defmodule Kapelle.Repo do
  use Ecto.Repo,
    otp_app: :kapelle,
    adapter: Ecto.Adapters.Postgres
end
