# Exclude :postgres_only tests when running SQLite
exclude =
  if WhisperLogs.DbAdapter.sqlite?() do
    [:postgres_only]
  else
    []
  end

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(WhisperLogs.Repo, :manual)
