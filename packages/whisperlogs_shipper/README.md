# WhisperLogs Shipper

An Elixir log shipper client for [WhisperLogs](https://github.com/dkulchenko/whisperlogs). Automatically captures all application logs and ships them to your WhisperLogs server in batches.

## Features

- **Zero-config logging**: Hooks into Erlang's `:logger` system - no code changes needed
- **Batched shipping**: Buffers logs and ships in configurable batches
- **Async HTTP**: Non-blocking log shipping via background tasks
- **Automatic flush**: Ships logs on batch size OR time interval (whichever first)
- **Test-friendly**: Supports synchronous task execution for deterministic tests

## Installation

Add to your `mix.exs`:

```elixir
# As a path dependency (for development or monorepo):
{:whisperlogs_shipper, path: "../packages/whisperlogs_shipper"}

# Or as a git dependency:
{:whisperlogs_shipper, github: "dkulchenko/whisperlogs", sparse: "packages/whisperlogs_shipper"}
```

## Configuration

### Runtime Configuration (Recommended)

Configure via environment variables in `config/runtime.exs`:

```elixir
# config/runtime.exs
if endpoint = System.get_env("WHISPERLOGS_ENDPOINT") do
  config :whisperlogs_shipper,
    enabled: true,
    endpoint: endpoint,
    auth_token: System.fetch_env!("WHISPERLOGS_AUTH_TOKEN")
end
```

### Compile-time Configuration

Or set defaults in `config/config.exs`:

```elixir
# config/config.exs
config :whisperlogs_shipper,
  enabled: true,
  endpoint: "http://localhost:4000/api/v1/logs",
  auth_token: "wl_your_api_key",
  batch_size: 100,
  flush_interval_ms: 1_000
```

### Test Configuration

Disable in tests to avoid shipping logs:

```elixir
# config/test.exs
config :whisperlogs_shipper,
  enabled: false,
  inline_tasks: true
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `WHISPERLOGS_ENDPOINT` | Yes | WhisperLogs API endpoint (e.g., `https://logs.example.com/api/v1/logs`) |
| `WHISPERLOGS_AUTH_TOKEN` | Yes | API token from WhisperLogs (starts with `wl_`) |

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `enabled` | `false` | Enable/disable log shipping |
| `endpoint` | `nil` | WhisperLogs API URL |
| `auth_token` | `nil` | Bearer token for authentication |
| `batch_size` | `100` | Ship after this many logs buffered |
| `flush_interval_ms` | `1000` | Ship after this many ms (even if batch not full) |
| `receive_timeout` | `10000` | HTTP receive timeout in ms |
| `inline_tasks` | `false` | Run HTTP tasks synchronously (for tests) |
| `source_name` | `nil` | Optional source identifier |

## Usage

Once configured, the shipper automatically starts and captures all logs. No code changes needed!

```elixir
# These logs are automatically captured and shipped:
require Logger

Logger.info("User signed in", user_id: 123)
Logger.error("Payment failed", order_id: 456, reason: "insufficient_funds")
```

### Manual Flush

Force an immediate flush (useful for graceful shutdown):

```elixir
WhisperLogs.Shipper.flush()
```

## How It Works

1. The shipper registers an Erlang `:logger` handler on startup
2. All log events flow through the handler, which formats them as JSON-compatible maps
3. Events are buffered in the GenServer
4. Buffer is flushed when batch size is reached OR flush interval elapses
5. Logs are shipped via async HTTP POST to the WhisperLogs API

## Testing

For testing with the shipper:

```elixir
# config/test.exs
config :whisperlogs_shipper,
  enabled: false,  # Don't start the shipper
  inline_tasks: true  # If enabled, run tasks synchronously

# Or if you want to test shipping behavior:
# Use Req.Test or Bypass to mock the HTTP endpoint
```

## License

MIT
