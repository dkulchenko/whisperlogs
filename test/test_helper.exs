# Exclude :postgres_only tests when running SQLite
exclude =
  if WhisperLogs.DbAdapter.sqlite?() do
    [:postgres_only]
  else
    []
  end

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(WhisperLogs.Repo, :manual)

# Start the S3 client mock agent for export tests
{:ok, _} = WhisperLogs.Exports.S3ClientMock.start_link()
