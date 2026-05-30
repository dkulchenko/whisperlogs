# `mix test` defaults to PostgreSQL so postgres_only coverage runs normally.
# Set WHISPERLOGS_TEST_ADAPTER=sqlite for explicit SQLite adapter runs.
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

# Start the Slack webhook mock agent for notification tests
{:ok, _} = WhisperLogs.Alerts.SlackWebhookClientMock.start_link()
