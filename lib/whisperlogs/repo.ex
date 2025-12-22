defmodule WhisperLogs.Repo do
  use Ecto.Repo,
    otp_app: :whisperlogs,
    adapter: Ecto.Adapters.Postgres
end
