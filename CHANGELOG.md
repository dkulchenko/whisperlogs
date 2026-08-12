# Changelog

## v0.6.1 - 2026-08-11

- Fix timestamp comparisons containing complete RFC 3339 times, including `Z`
  and numeric timezone offsets. Colons in the time value no longer split into
  unintended ANDed search terms.
- Add optional structured `since` and `until` fields to the MCP `search_logs`
  tool. Bounds apply to producer timestamps, with an inclusive lower bound and
  exclusive upper bound, and are cryptographically bound to pagination cursors.
- Accept slash-containing unquoted metadata values and the intuitive
  `metadata.<key>` prefix while retaining the existing direct `<key>:<value>`
  syntax.
- Expand model-facing tool instructions with concrete timestamp, metadata,
  level, and path-search examples; make the free-form query optional when
  structured time bounds are sufficient.

## v0.6.0 - 2026-08-11

### OAuth MCP log search

- Add a native, stateless Streamable HTTP MCP endpoint at `/mcp`, targeting the
  2026-07-28 protocol revision and exposing one read-only `search_logs` tool.
- Reuse WhisperLogs' existing search grammar with bounded pagination, encrypted
  query-bound cursors, database query deadlines, and response-size limits.
- Add OAuth 2.1 authorization-code authentication with PKCE S256, protected
  resource and authorization-server metadata, Client ID Metadata Documents,
  and a signed stateless dynamic-registration fallback for compatible clients.
- Issue one-hour access tokens and rotating 30-day refresh tokens as hashed
  opaque credentials. Revoke an entire grant on refresh-token replay, account
  password changes, or user-initiated connected-app revocation.
- Add an authenticated consent screen and a Connected apps section under user
  settings for reviewing and revoking MCP access.
- Harden remote client metadata retrieval against SSRF with HTTPS-only public
  destinations, DNS validation and address pinning, disabled redirects, finite
  deadlines, and bounded response bodies.
- Extend retention cleanup and the SQLite-to-PostgreSQL migrator to cover OAuth
  grants and tokens, and document public deployment, Codex setup, runtime
  limits, and the OAuth security model.

### Upgrade notes

- Run the included database migration before serving MCP traffic. It creates the
  OAuth grants and tokens tables on both supported database adapters.
- Public OAuth discovery and callbacks require an accurate `PHX_HOST` and HTTPS
  at the browser-facing boundary.
- Review the new `WHISPERLOGS_MCP_QUERY_TIMEOUT_MS`,
  `WHISPERLOGS_MCP_MAX_RESPONSE_BYTES`, and
  `WHISPERLOGS_MCP_MAX_QUERY_BYTES` limits before enabling remote access.

## v0.5.2 - 2026-08-09

- Make the full authenticated interface comfortable and usable on phones while
  preserving the existing desktop layout.
- Reflow log entries into readable mobile rows and reorganize the filter bar
  into touch-friendly wrapped controls with viewport-safe popovers.
- Stack forms, cards, badges, and action groups across sources, alerts, exports,
  notification channels, and account screens at narrow widths.
- Keep charts, dialogs, long values, and data tables within the viewport, using
  contained horizontal scrolling where tabular content needs its desktop width.

## v0.5.1 - 2026-08-07

- Fix the production container build by staging the SQLean configuration,
  checksum manifest, and native libraries before production configuration is
  evaluated during dependency compilation.
- Supersede v0.5.0 for container deployments; its image workflow failed before
  publishing an image. This patch otherwise contains the same application and
  security changes documented below.

## v0.5.0 - 2026-08-07

This release hardens WhisperLogs across authentication, ownership, ingestion,
alerts, exports, syslog, log shipping, and release inputs.

### Highlights

- Require a real authenticated browser session on both SQLite and PostgreSQL,
  gate startup on a serialized administrator bootstrap, and prevent public
  registration from creating administrators.
- Scope sources, alerts, notification channels, export destinations, and export
  jobs to their owners. Reject cross-owner relationships and enforce alert,
  export, and syslog quotas transactionally.
- Apply shared, atomic validation to HTTP and syslog ingestion with configurable
  request, batch, event, message, metadata, and nesting limits.
- Use observed insertion time for operational ordering, dashboards, alert
  cursors, retention, and scheduled exports while retaining producer timestamps
  for explicit event-time searches and manual exports.
- Remove the source authentication cache and asynchronous last-used updates so
  revocation takes effect immediately without unbounded cache or task growth.
- Bound alert preview and evaluator concurrency, fairly advance owners, enforce
  cycle deadlines, and cancel timed-out database work on both adapters.
- Serialize export admission and execution, use private derived workspaces,
  enforce row, byte, and time limits, and protect active scheduled ranges from
  retention.
- Harden multipart S3 exports with strict bucket and endpoint validation, an
  exact hostname allowlist, disabled redirects, finite request deadlines, and
  bounded response parsing.
- Add explicit syslog enablement, deny-by-default admission, quotas, bounded
  connections, frames, rates, queues, and ingest tasks, plus TLS framing and
  mTLS client identity checks.
- Rework the packaged shipper with admission before mailbox insertion, one
  bounded request in flight, bounded pending and response data, controlled
  transient retries, and terminal failure handling.
- Pin workflow actions and container images, serve fonts locally, and verify
  SQLean archives and runtime libraries against a single platform manifest.

### Upgrade notes

- This is a forward-only database upgrade. Stop the old process, back up the
  database, run the documented preflight, and do not restart an older release
  after migrations have run.
- Empty databases require `WHISPERLOGS_BOOTSTRAP_ADMIN_EMAIL` and an absolute,
  private `WHISPERLOGS_BOOTSTRAP_ADMIN_PASSWORD_FILE`. The recognized legacy
  passwordless SQLite administrator is upgraded in place using the same password
  file.
- Existing browser sessions are revoked once during migration. Users must sign
  in again.
- Legacy syslog sources migrate disabled. Review their transport, admission
  policy, and TLS identity configuration before explicitly re-enabling them.
- Non-loopback deployments issue Secure cookies and therefore require HTTPS at
  the browser-facing boundary.
- Every stored S3 endpoint must exactly match a hostname in
  `WHISPERLOGS_S3_ALLOWED_HOSTS`; wildcards, paths, ports, and implied subdomains
  are not accepted.
- Review the new runtime limits and deployment procedure in
  `docs/security-and-operations.md` and `docs/deployment.md` before upgrading.

## v0.4.0 - 2026-05-30

- Add an offline SQLite-to-PostgreSQL production migration task with release scripts.
- Preserve migrated data, IDs, timestamps, admin login, export history, and PostgreSQL sequences.
- Run test coverage in both PostgreSQL and SQLite modes via `mix test.adapters`.
- Make `mix precommit` run both adapter suites.
- Improve syslog listener test port allocation for reliability.
