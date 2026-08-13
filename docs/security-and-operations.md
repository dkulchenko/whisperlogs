# Security and operations reference

WhisperLogs requires one application process/container per database. Its schedulers and listeners
are local OTP processes, not distributed singletons. Deploy with stop-before-start replacement.
`DNS_CLUSTER_QUERY` is rejected. Native startup binds `127.0.0.1` by default; set
`WHISPERLOGS_BIND_IP=0.0.0.0` only when the surrounding container/network/firewall boundary is
intentional. A non-loopback `PHX_HOST` is assumed to be behind HTTPS and emits Secure, HttpOnly,
SameSite=Lax session and remember-me cookies.

## Identity and ownership

The synchronous bootstrap child runs after the selected Repo and before the endpoint. An empty
database requires `WHISPERLOGS_BOOTSTRAP_ADMIN_EMAIL` and an absolute
`WHISPERLOGS_BOOTSTRAP_ADMIN_PASSWORD_FILE`. The file must be a regular non-symlink, at most 1 KiB,
and inaccessible to group/other users. The only automatic upgrade is a database containing the
single passwordless `local@localhost` administrator, which is renamed to the required bootstrap
administrator email while its password is established. Ambiguous administrator states stop startup.

Both SQLite and PostgreSQL require a real browser session. Users share the log corpus, while
sources, alerts, notification channels, export destinations, and export jobs are owner-scoped.
Source bearer keys authenticate only enabled, non-revoked HTTP sources. Public registration is an
explicit application setting and can never create an administrator.

## OAuth and MCP

`POST /mcp` implements only the stateless MCP `2026-07-28` protocol and exposes the single
read-only `search_logs` tool. Every request requires an OAuth bearer token scoped to `logs:read`,
the exact `/mcp` resource indicator, matching protocol/body mirror headers, and a valid `Origin`
when that header is present. Discovery and token endpoints use the unauthenticated JSON pipeline;
consent uses the authenticated browser pipeline and its CSRF protection.

For MCP searches, prefer the structured RFC 3339 `since` and `until` arguments for time windows.
They apply to trusted server-observed time (`since` inclusive, `until` exclusive) and are bound to
the opaque pagination cursor along with the query and user. Producer-time filtering remains
available explicitly, for example `timestamp:>=2026-08-12T00:15:00Z level:error`.

Authorization codes expire after five minutes and require PKCE S256. Access tokens expire after
one hour. Refresh tokens rotate and expire after 30 days; replay of a consumed refresh token
revokes the complete grant. Only SHA-256 credential hashes are stored. Reauthorization,
user-initiated revocation, and password changes invalidate existing credentials. Expired OAuth
records and grants revoked for more than 90 days are removed by daily retention.

CIMD fetches require an HTTPS URL with a path, disable redirects, pin a DNS result after rejecting
non-public addresses, and enforce time/body limits. Deprecated DCR remains available as a
compatibility fallback and returns server-signed stateless public client IDs. Redirect URIs must
match exactly; HTTPS is required except for loopback HTTP callbacks used by native clients.

| Variable | Default |
| --- | ---: |
| `WHISPERLOGS_MCP_QUERY_TIMEOUT_MS` | 5000 |
| `WHISPERLOGS_MCP_MAX_RESPONSE_BYTES` | 1048576 |
| `WHISPERLOGS_MCP_MAX_QUERY_BYTES` | 4096 |

The response limit must be large enough for one complete maximum-sized log plus the MCP structured
content compatibility copy. Pagination cursors are encrypted, expire after 24 hours, and are bound
to the authorizing user and exact query.

## Ingestion and time

`timestamp` is producer-supplied event time. `inserted_at` is trusted server-observed time and
controls default ordering/pagination, structured MCP time bounds, metrics, alert windows/cursors,
retention, and scheduled exports. Explicit `timestamp:` search and manual export ranges continue
to use event time.
`level:` and `source:` search match either the dedicated column or the metadata value. Numeric
metadata comparisons accept JSON numbers and canonical decimal strings up to 128 bytes; other
JSON types and malformed values do not match, including under negation.

HTTP and syslog share atomic event validation. A failed event rejects the complete batch. The
following positive integer settings are parsed and validated at startup:

| Variable | Default |
| --- | ---: |
| `WHISPERLOGS_MAX_REQUEST_BYTES` | 8000000 |
| `WHISPERLOGS_MAX_BATCH_SIZE` | 250 |
| `WHISPERLOGS_MAX_MESSAGE_BYTES` | 65536 |
| `WHISPERLOGS_MAX_METADATA_BYTES` | 131072 |
| `WHISPERLOGS_MAX_METADATA_DEPTH` | 8 |
| `WHISPERLOGS_MAX_EVENT_BYTES` | 262144 |

Non-identity request content encodings are rejected. There is intentionally no sustained
per-source request budget or total application storage quota: operators must size, monitor, and
retain the database for valid sustained traffic.

## Alerts

Each user may store 100 alerts and enable 20; at most 500 are enabled globally. Count-and-mutate
operations are serialized in the database. The evaluator interleaves owners, evaluates with
bounded concurrency, and leaves timed-out alerts enabled and eligible for later cycles.

| Variable | Default |
| --- | ---: |
| `WHISPERLOGS_ALERT_MAX_CONCURRENCY` | 2 |
| `WHISPERLOGS_ALERT_QUERY_TIMEOUT_MS` | 5000 |
| `WHISPERLOGS_ALERT_CYCLE_TIMEOUT_MS` | 20000 |

Live preview has one debounced generation per socket and two tasks globally.

## Exports and S3

Local export paths are derived as `<WHISPERLOGS_EXPORT_ROOT>/<user-id>/<destination-id>` and are
not user input. SQLite defaults the root beside `DATABASE_PATH`; PostgreSQL requires an absolute
root. Per-job temporary workspaces are private and bounded exports run synchronously through the
single existing scheduler.

| Variable | Default |
| --- | ---: |
| `WHISPERLOGS_EXPORT_MAX_RANGE_DAYS` | 31 |
| `WHISPERLOGS_EXPORT_MAX_PENDING_PER_USER` | 2 |
| `WHISPERLOGS_EXPORT_MAX_PENDING_GLOBAL` | 10 |
| `WHISPERLOGS_EXPORT_MAX_ROWS` | 2000000 |
| `WHISPERLOGS_EXPORT_MAX_COMPRESSED_BYTES` | 536870912 |
| `WHISPERLOGS_EXPORT_TIMEOUT_SECONDS` | 1800 |

`WHISPERLOGS_S3_ALLOWED_HOSTS` is a comma-separated set of exact lowercase DNS hostnames. Stored
S3 destinations must use one of them and a virtual-host-safe bucket; every request is rebuilt as
`https://<bucket>.<allowed-host>/...`, revalidated, signed, bounded, and sent with redirects
disabled. Uploads use sequential 8 MiB multipart parts and abort on handled failure. Configure the
provider to abort incomplete multipart uploads after seven days because crash recovery is not
persisted.

Scheduled exports use observed time and admit one missing one-day range at a time. Manual exports
use event time and never advance the scheduled watermark. Retention protects pending/running
scheduled ranges, but a failed scheduled job releases its hold; logs may be deleted before a later
retry. This is the selected storage/availability tradeoff.

## Syslog

Each user may have 20 enabled, non-revoked syslog sources; the global maximum is 500. An empty
`allowlist` denies all traffic. `any` accepts every network-reachable sender and should be selected
only with an appropriate network boundary. UDP and plaintext TCP are explicitly insecure transport
choices. TLS requires TLS 1.2/1.3, a client CA, and at least one exact
`cert-sha256:<hex>` or `spki-sha256:<hex>` identity. Set the three TLS file variables only when TLS
listeners are used:

- `WHISPERLOGS_SYSLOG_TLS_CERT_FILE`
- `WHISPERLOGS_SYSLOG_TLS_KEY_FILE`
- `WHISPERLOGS_SYSLOG_TLS_CLIENT_CA_FILE`

| Variable | Default |
| --- | ---: |
| `WHISPERLOGS_SYSLOG_MAX_CONNECTIONS` | 128 |
| `WHISPERLOGS_SYSLOG_MAX_CONNECTIONS_PER_SOURCE` | 32 |
| `WHISPERLOGS_SYSLOG_MAX_FRAME_BYTES` | 65536 |
| `WHISPERLOGS_SYSLOG_MAX_QUEUED_PER_SOURCE` | 128 |
| `WHISPERLOGS_SYSLOG_MAX_QUEUED_GLOBAL` | 512 |
| `WHISPERLOGS_SYSLOG_INGEST_WORKERS` | 2 |
| `WHISPERLOGS_SYSLOG_IDLE_TIMEOUT_MS` | 300000 |
| `WHISPERLOGS_SYSLOG_TLS_HANDSHAKE_TIMEOUT_MS` | 5000 |

## Elixir shipper

The included shipper normalizes and encodes before casting, reserves admitted event/byte capacity
atomically, and makes one finite-time Req call at a time. Network failures, 408, 425, 429, and 5xx
retain the in-flight batch and retry with exponential full jitter capped at 60 seconds. Other 4xx
responses deliberately drop the whole batch and continue. It has no disk spool.

| Application option | Default |
| --- | ---: |
| `max_admitted_events` | 10000 |
| `max_admitted_bytes` | 33554432 |
| `batch_size` | 100 |
| `max_request_bytes` | 7500000 |
| `flush_interval_ms` | 1000 |
| `max_message_bytes` | 65536 |
| `max_metadata_bytes` | 131072 |
| `max_metadata_depth` | 8 |
| `max_event_bytes` | 262144 |

Keep the shipper request maximum below the receiver request maximum.

## Build inputs

Release workflow actions and Docker base images use immutable commit/digest references. Inter and
Source Code Pro are served from `priv/static/fonts` with their licenses and source revisions.
SQLite loads SQLean only after its platform library matches the checked-in 0.28.1 manifest; the
download script verifies both archives and staged libraries before replacement.
