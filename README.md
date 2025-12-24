# WhisperLogs

A lightweight, self-hosted log aggregation and alerting system. Collect logs from any application, search them in real-time, and set up intelligent alerts.

![WhisperLogs Screenshot](screenshot.png)

## Quick Start

1. Download the latest release for your platform from the [releases page](https://github.com/dkulchenko/whisperlogs/releases)
2. Run the executable:

```bash
./whisperlogs_linux      # Linux x86_64
./whisperlogs_linux_arm  # Linux ARM64
./whisperlogs_macos      # macOS Intel
./whisperlogs_macos_arm  # macOS Apple Silicon
whisperlogs_windows.exe  # Windows
```

3. Open http://localhost:4050

That's it!

## Features

### Live Log Viewer
- **Real-time streaming** with live tail that follows new logs as they arrive
- **Infinite scroll** in both directions - scroll up for older logs, down for newer
- **Expandable log details** showing metadata, timestamps, and copy-to-clipboard actions
- **Request ID tracking** - click any request ID to filter related logs across your stack
- **Network delay indicators** - see how long logs took to arrive (color-coded by severity)

### Powerful Search
Find exactly what you need with an expressive query syntax:
- `error` - search message and metadata
- `user_id:123` - filter by metadata field
- `duration_ms:>500` - numeric comparisons
- `"connection refused"` - exact phrases
- `-debug` - exclude terms
- `level:error timestamp:>-1h` - combine multiple filters

Real-time syntax highlighting shows you exactly how your query is interpreted.

### Smart Alerting
- **Pattern alerts** - trigger immediately when a log matches your search
- **Velocity alerts** - trigger when matches exceed a threshold (e.g., "more than 100 errors in 5 minutes")
- **Live preview** - see how many logs match before saving
- **Cooldown periods** - prevent alert fatigue

### Notifications
Route alerts to the channels you already use:
- **Email** - simple SMTP delivery
- **Pushover** - mobile push notifications with priority levels

### Metrics Dashboard
- Total log volume and storage usage
- Hourly, daily, and monthly breakdowns with interactive charts
- 30-day projections based on current velocity

### Flexible Ingestion
Collect logs from anywhere:
- **HTTP API** - POST JSON from any language
- **Syslog** - RFC 3164 and RFC 5424 support (UDP/TCP)
- **Elixir Shipper** - zero-config Logger integration

## Sending Logs

WhisperLogs supports three ways to ingest logs:

### HTTP API (Any Language)

Send logs via HTTP POST to any WhisperLogs server:

1. Create an HTTP source in the WhisperLogs UI (Sources page)
2. Copy the API key (starts with `wl_`)
3. POST logs to `/api/v1/logs`:

```bash
curl -X POST https://your-whisperlogs-server/api/v1/logs \
  -H "Authorization: Bearer wl_your_api_key" \
  -H "Content-Type: application/json" \
  -d '{
    "logs": [
      {
        "timestamp": "2024-01-15T10:30:00.123456Z",
        "level": "info",
        "message": "User signed in",
        "metadata": {"user_id": 123, "ip": "192.168.1.1"}
      }
    ]
  }'
```

**Payload format:**

| Field | Required | Description |
|-------|----------|-------------|
| `timestamp` | No | ISO 8601 timestamp (defaults to server time) |
| `level` | No | Log level: `debug`, `info`, `warning`, `error` |
| `message` | Yes | Log message text |
| `metadata` | No | JSON object with additional data |
| `request_id` | No | Request correlation ID |

### WhisperLogs Shipper (Elixir Apps)

For Elixir applications, use the included shipper package for automatic log capture:

**Installation:**

Add to your `mix.exs`:

```elixir
{:whisperlogs_shipper, github: "dkulchenko/whisperlogs", sparse: "packages/whisperlogs_shipper"}
```

**Configuration:**

```elixir
# config/runtime.exs
if endpoint = System.get_env("WHISPERLOGS_ENDPOINT") do
  config :whisperlogs_shipper,
    enabled: true,
    endpoint: endpoint,
    auth_token: System.fetch_env!("WHISPERLOGS_AUTH_TOKEN")
end
```

**Usage:**

No code changes required! The shipper automatically hooks into Erlang's `:logger` system:

```elixir
require Logger

Logger.info("User signed in", user_id: 123)
# Automatically captured and shipped to WhisperLogs
```

**Environment variables:**

| Variable | Description |
|----------|-------------|
| `WHISPERLOGS_ENDPOINT` | WhisperLogs API endpoint (e.g., `https://logs.example.com/api/v1/logs`) |
| `WHISPERLOGS_AUTH_TOKEN` | API key from WhisperLogs (starts with `wl_`) |

See [packages/whisperlogs_shipper/README.md](packages/whisperlogs_shipper/README.md) for full documentation.

### Syslog (Any Environment)

WhisperLogs can receive logs via standard syslog protocol (RFC 3164 and RFC 5424):

1. Create a Syslog source in the WhisperLogs UI (Sources page)
2. Configure the port (1024-65535) and transport (UDP, TCP, or both)
3. Point your applications or systems to the syslog endpoint:

```bash
# Example: Send logs via logger command (Linux)
logger -n your-whisperlogs-server -P 5514 "Application started"

# Example: Configure rsyslog to forward logs
# /etc/rsyslog.d/whisperlogs.conf
*.* @your-whisperlogs-server:5514
```

**Syslog features:**
- UDP and TCP support (configurable per source)
- Host allow-listing for security
- Auto-registration of new hosts (optional)
- Automatic severity-to-level mapping

## Production Deployment

By default, WhisperLogs uses SQLite which requires no configuration. For production deployments with multiple users or high concurrency, you can use PostgreSQL instead.

### Using PostgreSQL

Set the `DATABASE_URL` environment variable to switch to PostgreSQL mode:

```bash
export DATABASE_URL="postgres://user:password@localhost:5432/whisperlogs"
export SECRET_KEY_BASE="$(openssl rand -base64 48)"
./whisperlogs_linux eval "WhisperLogs.Release.migrate()"
./whisperlogs_linux
```

Then open the browser and register the first user account.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | - | PostgreSQL connection URL (enables PostgreSQL mode) |
| `DATABASE_PATH` | `~/.local/share/whisperlogs/db.sqlite` | SQLite database path |
| `SECRET_KEY_BASE` | - | Required for PostgreSQL mode |
| `PHX_HOST` | `localhost` | Server hostname |
| `PORT` | `4050` | Web server port |
| `POOL_SIZE` | `10` | Database connection pool size |

## Development

### Prerequisites

- Elixir 1.15+
- Node.js 18+
- PostgreSQL 15+ (optional)

### Setup

```bash
git clone https://github.com/dkulchenko/whisperlogs.git
cd whisperlogs
mix setup
mix phx.server
```

Open http://localhost:4050

### Running Tests

```bash
mix test
```

### Building Standalone Executables

```bash
MIX_ENV=prod mix release
```

Executables are output to `burrito_out/`.

## License

MIT
