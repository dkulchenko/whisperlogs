defmodule WhisperLogs.Repo.SQLite do
  @moduledoc """
  SQLite repository for single-user local mode.
  """

  use Ecto.Repo,
    otp_app: :whisperlogs,
    adapter: Ecto.Adapters.SQLite3
end
