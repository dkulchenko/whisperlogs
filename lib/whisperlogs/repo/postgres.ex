defmodule WhisperLogs.Repo.Postgres do
  @moduledoc """
  PostgreSQL repository for multi-user server mode.
  """

  use Ecto.Repo,
    otp_app: :whisperlogs,
    adapter: Ecto.Adapters.Postgres
end
