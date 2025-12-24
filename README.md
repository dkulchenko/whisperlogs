# WhisperLogs

A lightweight, self-hosted log aggregation and alerting system. Collect logs from any application, search them in real-time, and set up intelligent alerts.

![WhisperLogs Screenshot](screenshot.png)

## Quick Start

The easiest way to run WhisperLogs is using the standalone executable:

1. Download the latest release for your platform from the [releases page](https://github.com/dkulchenko/whisperlogs/releases)
2. Run the executable:

```bash
./whisperlogs_linux      # Linux x86_64
./whisperlogs_linux_arm  # Linux ARM64
./whisperlogs_macos      # macOS Intel
./whisperlogs_macos_arm  # macOS Apple Silicon
whisperlogs_windows.exe  # Windows
```

3. Open http://localhost:4000 in your browser
4. Register the first user account

That's it! WhisperLogs automatically creates a SQLite database and runs migrations on first start.

## SQLite Mode vs PostgreSQL Mode

WhisperLogs supports two database modes, automatically selected at runtime:

| Aspect | SQLite (Default) | PostgreSQL |
|--------|------------------|------------|
| **Activation** | No `DATABASE_URL` set | `DATABASE_URL` environment variable set |
| **Setup** | Zero-config, auto-migrates on startup | Requires manual migration |
| **Use case** | Development, single-server, personal use | Production, multi-user, high concurrency |
| **Data location** | `~/.local/share/whisperlogs/db.sqlite` | Remote PostgreSQL server |

### Using PostgreSQL Mode

```bash
export DATABASE_URL="postgres://user:password@localhost:5432/whisperlogs"
export SECRET_KEY_BASE="$(openssl rand -base64 48)"
./whisperlogs_linux
```

For PostgreSQL, run migrations before first use:

```bash
./whisperlogs_linux eval "WhisperLogs.Release.migrate()"
```

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

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | - | PostgreSQL connection URL. If set, uses PostgreSQL mode |
| `DATABASE_PATH` | `~/.local/share/whisperlogs/db.sqlite` | SQLite database path |
| `SECRET_KEY_BASE` | - | Required for session encryption in production |
| `PHX_HOST` | `localhost` | Server hostname |
| `PORT` | `4000` | Web server port |
| `POOL_SIZE` | `10` | Database connection pool size |

## Features

- **Real-time log viewing** - Live tail with instant updates as logs arrive
- **Advanced search** - Query by text, metadata fields, log levels, and time ranges
- **Alerting system** - Trigger alerts on log patterns with velocity thresholds
- **Notification channels** - Route alerts to email, webhooks, and more
- **Metrics dashboard** - Track log volume, storage usage, and trends
- **Multi-source support** - Aggregate logs from multiple applications
- **Retention management** - Automatic log cleanup based on age

## Development

### Prerequisites

- Elixir 1.15+
- Node.js 18+
- PostgreSQL 15+ (optional, for PostgreSQL mode)

### Setup

```bash
git clone https://github.com/dkulchenko/whisperlogs.git
cd whisperlogs
mix setup
```

### Running the Server

```bash
mix phx.server
# Or with IEx console:
iex -S mix phx.server
```

Open http://localhost:4000

### Running Tests

```bash
mix test
```

### Building Standalone Executables

Build executables for all platforms using Burrito:

```bash
MIX_ENV=prod mix release
```

Executables are output to `burrito_out/`:
- `whisperlogs_linux` - Linux x86_64
- `whisperlogs_linux_arm` - Linux ARM64
- `whisperlogs_macos` - macOS Intel
- `whisperlogs_macos_arm` - macOS Apple Silicon
- `whisperlogs_windows.exe` - Windows x86_64

## License

MIT
