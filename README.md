# WhisperLogs

A lightweight, self-hosted log aggregation and alerting system. Collect logs from any application, search them in real-time, and set up intelligent alerts.

![WhisperLogs Screenshot](screenshot.png)

## Quick Start

1. Download the latest release for your platform from the [releases page](https://github.com/dkulchenko/whisperlogs/releases)
2. Create a private bootstrap password file and run the executable:

```bash
install -m 600 /dev/null ./whisperlogs_admin_password
printf '%s' 'replace-with-a-long-password' > ./whisperlogs_admin_password
export WHISPERLOGS_BOOTSTRAP_ADMIN_EMAIL=admin@example.com
export WHISPERLOGS_BOOTSTRAP_ADMIN_PASSWORD_FILE="$PWD/whisperlogs_admin_password"

./whisperlogs_linux      # Linux x86_64
./whisperlogs_linux_arm  # Linux ARM64
./whisperlogs_macos      # macOS Intel
./whisperlogs_macos_arm  # macOS Apple Silicon
whisperlogs_windows.exe  # Windows
```

3. Open http://localhost:4050

SQLite defaults to a loopback listener and persists its generated session secret beside the
database. The bootstrap variables are required only while creating the first administrator (or
upgrading the recognized legacy `local@localhost` account). During that legacy upgrade, the
account is changed to the configured bootstrap administrator email.

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
- **Elixir Shipper** - bounded Logger integration with finite HTTP timeouts and retries

### OAuth MCP log search

WhisperLogs exposes one read-only remote MCP tool, `search_logs`, over stateless Streamable HTTP.
It uses the MCP `2026-07-28` protocol and OAuth 2.1 authorization-code flow with PKCE. Any signed-in
WhisperLogs user may approve a client; connected clients can only read the same shared log corpus
available in the web log viewer. Connections can be revoked under **Account Settings → Connected
apps**.

For a public deployment, set `PHX_HOST` to its external hostname and terminate HTTPS at the reverse
proxy. The OAuth resource URL is then `https://<PHX_HOST>/mcp`. Add it to Codex and complete the
browser consent flow:

```bash
codex mcp add whisperlogs --url https://logs.example.com/mcp
codex mcp login whisperlogs
```

`search_logs` accepts optional RFC 3339 `since` (inclusive) and `until` (exclusive) fields; prefer
these structured fields for time windows. Its optional `query` field supports terms and ANDed
filters such as `level:error stripe`, `request_path:"/checkout"`, and
`timestamp:>=2026-08-12T00:15:00Z`. Metadata keys can also use the explicit
`metadata.request_path:/checkout` form.

Codex can use Client ID Metadata Documents when supplied and otherwise falls back to stateless
Dynamic Client Registration. See the [official OpenAI MCP documentation](https://developers.openai.com/codex/mcp/)
for current Codex client configuration.

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
| `message` | No | Log message text (defaults to an empty string) |
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
2. Configure the port (1024-65535), admission policy, and transport (UDP, TCP, both, or mTLS)
3. Point your applications or systems to the syslog endpoint:

```bash
# Example: Send logs via logger command (Linux)
logger -n your-whisperlogs-server -P 5514 "Application started"

# Example: Configure rsyslog to forward logs
# /etc/rsyslog.d/whisperlogs.conf
*.* @your-whisperlogs-server:5514
```

**Syslog features:**
- UDP and plaintext TCP as explicit warned choices, plus TLS 1.2/1.3 with required client certificates
- Deny-by-default IP/CIDR allowlists, or an explicit `any` admission mode
- Per-source typed certificate/SPKI SHA-256 identity allowlists for mTLS rotation
- Bounded frames, connections, queues, and ingest workers
- Automatic severity-to-level mapping

## Production Deployment

WhisperLogs supports SQLite and PostgreSQL. Every database must have exactly one running
WhisperLogs application process: use stop-before-start replacement, not overlapping rolling
deployments. PostgreSQL does not make the recurring schedulers/listeners distributed singletons.

### Docker (SQLite with Durable Storage by Default)

Build the image:

```bash
docker build -t whisperlogs:latest .
```

Run with a persistent Docker volume:

```bash
docker run -d \
  --name whisperlogs \
  -p 127.0.0.1:4050:4050 \
  -v whisperlogs_data:/var/lib/whisperlogs \
  -v "$PWD/whisperlogs_admin_password:/run/secrets/whisperlogs_admin_password:ro" \
  -e WHISPERLOGS_BIND_IP=0.0.0.0 \
  -e WHISPERLOGS_BOOTSTRAP_ADMIN_EMAIL=admin@example.com \
  -e WHISPERLOGS_BOOTSTRAP_ADMIN_PASSWORD_FILE=/run/secrets/whisperlogs_admin_password \
  whisperlogs:latest
```

SQLite data is stored at `/var/lib/whisperlogs/db.sqlite` in the container, so mounting `/var/lib/whisperlogs` keeps logs and state across restarts.

You can also use Docker Compose:

```bash
docker compose up -d --build
```

The included `docker-compose.yml` uses SQLite by default with durable storage and exposes the web UI on port `4050`.

If you configure Syslog sources, publish those ports too (for example `5514/tcp` or `5514/udp`).

### Docker + PostgreSQL

Set `DATABASE_URL` to switch to PostgreSQL mode. In Docker, pending migrations are run automatically at container startup before the app boots.

Set `SECRET_KEY_BASE` in PostgreSQL deployments. SQLite creates a private persistent secret next
to `DATABASE_PATH` when one is not supplied.

### Using PostgreSQL

Set the `DATABASE_URL` environment variable to switch to PostgreSQL mode:

```bash
export DATABASE_URL="postgres://user:password@localhost:5432/whisperlogs"
export SECRET_KEY_BASE="$(openssl rand -base64 48)"
export WHISPERLOGS_EXPORT_ROOT="/var/lib/whisperlogs/exports"
export WHISPERLOGS_BOOTSTRAP_ADMIN_EMAIL="admin@example.com"
export WHISPERLOGS_BOOTSTRAP_ADMIN_PASSWORD_FILE="$PWD/whisperlogs_admin_password"
./whisperlogs_linux eval "WhisperLogs.Release.migrate()"
./whisperlogs_linux
```

The bootstrap child creates the initial administrator before the endpoint starts. Public
registration is disabled unless `config :whisperlogs, :registration, allow_public: true` is set;
public registration always creates non-admin users.

### Migrating SQLite data to PostgreSQL

Stop WhisperLogs before migrating so the SQLite database cannot change during the copy. The
PostgreSQL target should be empty; the migration task runs migrations, copies all application
tables, verifies row counts, and preserves the source administrator. A recognized passwordless
legacy `local@localhost` administrator is upgraded to `WHISPERLOGS_BOOTSTRAP_ADMIN_EMAIL` using
the same private password file contract.

```bash
export DATABASE_URL="postgres://user:password@localhost:5432/whisperlogs"
export SQLITE_DATABASE_PATH="/var/lib/whisperlogs/db.sqlite"
export SECRET_KEY_BASE="$(openssl rand -base64 48)"
export WHISPERLOGS_BOOTSTRAP_ADMIN_EMAIL="admin@example.com"
export WHISPERLOGS_BOOTSTRAP_ADMIN_PASSWORD_FILE="$PWD/whisperlogs_admin_password"
./whisperlogs_linux eval "WhisperLogs.Release.migrate_sqlite_to_postgres()"
```

Use `MIGRATION_BATCH_SIZE` to tune copy batches. Set
`MIGRATION_ALLOW_NON_EMPTY_TARGET=true` only if you intentionally want to copy into a target
that already has application rows.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | - | PostgreSQL connection URL (enables PostgreSQL mode) |
| `DATABASE_PATH` | `~/.local/share/whisperlogs/db.sqlite` | SQLite database path |
| `SQLITE_DATABASE_PATH` | `DATABASE_PATH` | Source SQLite database path for SQLite-to-PostgreSQL migration |
| `WHISPERLOGS_BOOTSTRAP_ADMIN_EMAIL` | - | Initial administrator email, also used to rename the recognized legacy administrator |
| `WHISPERLOGS_BOOTSTRAP_ADMIN_PASSWORD_FILE` | - | Absolute private regular file containing the initial/legacy administrator password |
| `MIGRATION_BATCH_SIZE` | `1000` | Rows per batch during SQLite-to-PostgreSQL migration |
| `MIGRATION_ALLOW_NON_EMPTY_TARGET` | `false` | Allow migration into a PostgreSQL target with existing application rows |
| `SECRET_KEY_BASE` | SQLite: persisted automatically | Required for PostgreSQL mode |
| `PHX_HOST` | `localhost` | Server hostname |
| `WHISPERLOGS_BIND_IP` | `127.0.0.1` | IP literal to bind; containers normally set `0.0.0.0` and publish a loopback host port |
| `PORT` | `4050` | Web server port |
| `POOL_SIZE` | `10` | Database connection pool size |
| `WHISPERLOGS_MCP_QUERY_TIMEOUT_MS` | `5000` | Maximum database time for one MCP log search |
| `WHISPERLOGS_MCP_MAX_RESPONSE_BYTES` | `1048576` | Maximum MCP tool-result size, including the compatibility text copy |
| `WHISPERLOGS_MCP_MAX_QUERY_BYTES` | `4096` | Maximum UTF-8 byte length of an MCP search query |

See [the security and operations reference](docs/security-and-operations.md) for all validated
limits, time semantics, ownership rules, export/S3 behavior, and shipper retry policy. See
[the deployment runbook](docs/deployment.md) before upgrading an existing installation.

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

### Release Automation

GitHub release publishing automatically triggers:

- `.github/workflows/docker-release.yml` to build and push multi-arch Docker images to GHCR
- `.github/workflows/burrito-release.yml` to run `MIX_ENV=prod mix release whisperlogs` and upload `burrito_out/*` binaries to the same GitHub release

Both workflows build from the exact release tag (`vX.Y.Z`) so Docker images and Burrito binaries match the tagged source.

## License

MIT
