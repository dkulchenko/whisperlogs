import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Disable auto-migration in tests - mix test handles it
config :whisperlogs, :auto_migrate, false
config :whisperlogs, :bootstrap, enabled: false
config :whisperlogs, :start_background_workers, false
config :whisperlogs, :s3_allowed_hosts, ["s3.amazonaws.com"]

if System.get_env("WHISPERLOGS_TEST_ADAPTER") == "sqlite" do
  config :whisperlogs, :alert_limits, %{
    max_concurrency: 1,
    query_timeout_ms: 5_000,
    cycle_timeout_ms: 20_000
  }
end

# Configure both database repos - runtime.exs decides which one to start

{verify_sqlean, _binding} = Code.eval_file(Path.join(__DIR__, "sqlean.exs"))
sqlean_regexp_ext = verify_sqlean.()

# SQLite config (used when no DATABASE_URL)
# Use pool_size: 1 to avoid "Database busy" errors with concurrent tests
config :whisperlogs, WhisperLogs.Repo.SQLite,
  database: Path.expand("../priv/test.db", __DIR__),
  load_extensions: [sqlean_regexp_ext],
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1,
  journal_mode: :wal,
  busy_timeout: 5000,
  synchronous: :normal,
  cache_size: -64000,
  auto_vacuum: :incremental,
  temp_store: :memory

# PostgreSQL config (default test adapter; DATABASE_URL overrides host settings)
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
postgres_config = [
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "whisperlogs_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10
]

postgres_config =
  if database_url = System.get_env("DATABASE_URL") do
    Keyword.put(postgres_config, :url, database_url)
  else
    postgres_config
  end

config :whisperlogs, WhisperLogs.Repo.Postgres, postgres_config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :whisperlogs, WhisperLogsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "FBpasQnxNMEZp2qPtF+9ng/XPsUq5nDoFA2rIYfMFCr+i1+t0i6dVBzmDkqumbsa",
  server: false

# In test we don't send emails
config :whisperlogs, WhisperLogs.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
