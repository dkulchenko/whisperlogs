# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :whisperlogs, :scopes,
  user: [
    default: true,
    module: WhisperLogs.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: WhisperLogs.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

# Database adapter is set at runtime in runtime.exs based on DATABASE_URL
# Default to :sqlite for compile-time (macros, etc.) - runtime.exs overrides
config :whisperlogs, :db_adapter, :sqlite

config :whisperlogs,
  namespace: WhisperLogs,
  ecto_repos: [WhisperLogs.Repo],
  generators: [timestamp_type: :utc_datetime]

# Registration is explicit; bootstrap owns initial account creation.
config :whisperlogs, :registration, allow_public: false

config :whisperlogs, :bootstrap, enabled: true

config :whisperlogs, :receiver_limits, %{
  max_request_bytes: 8_000_000,
  max_batch_size: 250,
  max_message_bytes: 65_536,
  max_metadata_bytes: 131_072,
  max_metadata_depth: 8,
  max_event_bytes: 262_144
}

config :whisperlogs, :export_limits, %{
  max_range_days: 31,
  max_pending_per_user: 2,
  max_pending_global: 10,
  max_rows: 2_000_000,
  max_compressed_bytes: 536_870_912,
  timeout_seconds: 1_800
}

config :whisperlogs, :alert_limits, %{
  max_concurrency: 2,
  query_timeout_ms: 5_000,
  cycle_timeout_ms: 20_000
}

config :whisperlogs, :syslog_limits, %{
  max_connections: 128,
  max_connections_per_source: 32,
  max_frame_bytes: 65_536,
  max_queued_per_source: 128,
  max_queued_global: 512,
  ingest_workers: 2,
  idle_timeout_ms: 300_000,
  tls_handshake_timeout_ms: 5_000
}

config :whisperlogs, :s3_allowed_hosts, []
config :whisperlogs, :export_root, Path.expand("../exports", __DIR__)
config :whisperlogs, :dns_cluster_query, nil

# Configure the endpoint
config :whisperlogs, WhisperLogsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: WhisperLogsWeb.ErrorHTML, json: WhisperLogsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: WhisperLogs.PubSub,
  live_view: [signing_salt: "Ou1vM91/"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :whisperlogs, WhisperLogs.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.1",
  whisperlogs: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  whisperlogs: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure timezone database for PST/PDT support
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
