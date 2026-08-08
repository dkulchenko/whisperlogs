# Changelog

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
