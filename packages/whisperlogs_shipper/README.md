# WhisperLogs Shipper

An Elixir log shipper client for [WhisperLogs](https://github.com/dkulchenko/whisperlogs). Automatically captures all application logs and ships them to your WhisperLogs server in batches.

## Features

- **Zero-config logging**: Hooks into Erlang's `:logger` system - no code changes needed
- **Bounded admission**: Reserves event and encoded-byte capacity before casting to the shipper
- **Exact request batching**: Counts the complete JSON envelope before sending
- **Single in-flight request**: One finite-time Req call and at most one retry timer
- **Automatic flush**: Ships logs on batch size OR time interval (whichever first)
- **Controlled recovery**: Transient failures retain order; terminal 4xx responses drop one batch

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
  max_admitted_events: 10_000,
  max_admitted_bytes: 33_554_432,
  max_request_bytes: 7_500_000,
  flush_interval_ms: 1_000
```

### Test Configuration

Disable in tests to avoid shipping logs:

```elixir
# config/test.exs
config :whisperlogs_shipper,
  enabled: false
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
| `max_admitted_events` | `10000` | Maximum events reserved across mailbox, pending, and in-flight state |
| `max_admitted_bytes` | `33554432` | Maximum encoded event bytes reserved before cast |
| `max_request_bytes` | `7500000` | Maximum complete encoded JSON request; keep below the receiver limit |
| `max_message_bytes` | `65536` | Maximum UTF-8 message bytes |
| `max_metadata_bytes` | `131072` | Maximum encoded metadata bytes |
| `max_metadata_depth` | `8` | Maximum map/list nesting depth including the root metadata object |
| `max_event_bytes` | `262144` | Maximum normalized encoded event bytes |
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
3. The caller atomically reserves bounded count/byte capacity before casting
4. Events are buffered in one GenServer and split by count and exact request-envelope bytes
5. One synchronous, finite-time HTTP request is in flight at a time
6. Network failures, 408, 425, 429, and 5xx retry with exponential full jitter capped at 60 seconds
7. Other 4xx responses drop that whole batch with a bounded payload-free warning and continue

Reservations are released only after success or deliberate terminal drop. There is no disk spool;
events still reserved in memory are lost if the host process exits.

## Testing

For testing with the shipper:

```elixir
# config/test.exs
config :whisperlogs_shipper,
  enabled: false  # Don't start the shipper

# Or if you want to test shipping behavior:
# Use Req.Test or Bypass to mock the HTTP endpoint
```

## License

MIT
