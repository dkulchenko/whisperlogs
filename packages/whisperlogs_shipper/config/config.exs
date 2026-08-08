import Config

# Default configuration - disabled by default
# Override these in your application's config or via environment variables
config :whisperlogs_shipper,
  # Set to true to enable log shipping
  enabled: false,
  # WhisperLogs API endpoint (e.g., "https://logs.example.com/api/v1/logs")
  endpoint: nil,
  # API token from WhisperLogs (starts with "wl_")
  auth_token: nil,
  # Number of logs to buffer before shipping
  batch_size: 100,
  max_admitted_events: 10_000,
  max_admitted_bytes: 33_554_432,
  max_request_bytes: 7_500_000,
  max_message_bytes: 65_536,
  max_metadata_bytes: 131_072,
  max_metadata_depth: 8,
  max_event_bytes: 262_144,
  # Maximum time (ms) to wait before flushing buffered logs
  flush_interval_ms: 1_000,
  # HTTP receive timeout (ms)
  receive_timeout: 10_000,
  # Optional source name for identifying this application
  source_name: nil
