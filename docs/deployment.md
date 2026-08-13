# Upgrade and deployment runbook

This release is a forward-only application/database rollout. Do not start an older image after its
migrations run. Exactly one WhisperLogs process/container may use a database; stop the old process
before migration and keep it stopped until the replacement starts.

## 1. Stop, back up, and inspect

Stop WhisperLogs first. For SQLite, prefer the SQLite backup operation. Otherwise copy
`db.sqlite`, plus `db.sqlite-wal` and `db.sqlite-shm` when present, into one timestamped recovery
directory while stopped. Never copy only the main file from a live WAL database.

Open a clone of the backup and record:

```sql
PRAGMA quick_check;
PRAGMA user_version;
SELECT 'users', COUNT(*) FROM users
UNION ALL SELECT 'sources', COUNT(*) FROM sources
UNION ALL SELECT 'alerts', COUNT(*) FROM alerts
UNION ALL SELECT 'notification_channels', COUNT(*) FROM notification_channels
UNION ALL SELECT 'export_destinations', COUNT(*) FROM export_destinations
UNION ALL SELECT 'export_jobs', COUNT(*) FROM export_jobs
UNION ALL SELECT 'logs', COUNT(*) FROM logs;
```

Require `quick_check` to return `ok`. Save the schema version and counts with the backup.

## 2. Run the narrow preflight queries

Run the administrator, ownership, join, alert, export, and S3 inventory queries against the
unmodified backup clone first. Then migrate a second disposable clone and run the enabled-syslog
queries against that clone, because `enabled` is introduced by this release. These are read-only
except for the separately identified cross-owner join cleanup performed by the migration. Every
query below must return zero rows/count unless its note says otherwise.

Administrator and session state:

```sql
SELECT COUNT(*) AS users FROM users;
SELECT id, email, is_admin, (hashed_password IS NOT NULL) AS has_password FROM users ORDER BY id;
SELECT context, COUNT(*) FROM users_tokens GROUP BY context ORDER BY context;
```

The accepted pre-migration states are one password-bearing administrator plus any number of
non-admin users, or the single passwordless legacy `local@localhost` administrator. The legacy
administrator is renamed to the configured bootstrap email while its password is established.
Existing `session` tokens will be revoked once by migration.

Null, dangling, and cross-owner records:

```sql
SELECT COUNT(*) FROM sources WHERE user_id IS NULL;
SELECT COUNT(*) FROM alerts WHERE user_id IS NULL;
SELECT COUNT(*) FROM notification_channels WHERE user_id IS NULL;
SELECT COUNT(*) FROM export_destinations WHERE user_id IS NULL;
SELECT COUNT(*) FROM export_jobs WHERE user_id IS NULL;

SELECT COUNT(*) FROM sources s LEFT JOIN users u ON u.id = s.user_id WHERE u.id IS NULL;
SELECT COUNT(*) FROM alerts a LEFT JOIN users u ON u.id = a.user_id WHERE u.id IS NULL;
SELECT COUNT(*) FROM notification_channels c LEFT JOIN users u ON u.id = c.user_id WHERE u.id IS NULL;
SELECT COUNT(*) FROM export_destinations d LEFT JOIN users u ON u.id = d.user_id WHERE u.id IS NULL;
SELECT COUNT(*) FROM export_jobs j LEFT JOIN users u ON u.id = j.user_id WHERE u.id IS NULL;

SELECT anc.id, a.user_id AS alert_owner, c.user_id AS channel_owner
FROM alert_notification_channels anc
LEFT JOIN alerts a ON a.id = anc.alert_id
LEFT JOIN notification_channels c ON c.id = anc.notification_channel_id
WHERE a.id IS NULL OR c.id IS NULL OR a.user_id <> c.user_id;

SELECT j.id, j.user_id AS job_owner, d.user_id AS destination_owner
FROM export_jobs j
LEFT JOIN export_destinations d ON d.id = j.export_destination_id
WHERE d.id IS NULL OR j.user_id <> d.user_id;
```

Only null-owned alert/channel/destination/job rows from the recognized single-user legacy SQLite
layout are reassigned to `local@localhost`. Every other null/dangling/ambiguous owner aborts. The
migration deletes the listed cross-owner alert/channel joins; review and record them first.

Alert quotas (100 stored and 20 enabled per user, 500 enabled globally):

```sql
SELECT user_id, COUNT(*) FROM alerts GROUP BY user_id HAVING COUNT(*) > 100;
SELECT user_id, COUNT(*) FROM alerts WHERE enabled = TRUE GROUP BY user_id HAVING COUNT(*) > 20;
SELECT COUNT(*) FROM alerts WHERE enabled = TRUE;
```

The final count must be at most 500.

Enabled syslog state on the migrated disposable clone (20 per user, 500 globally):

```sql
SELECT user_id, COUNT(*)
FROM sources
WHERE type = 'syslog' AND enabled = TRUE AND revoked_at IS NULL
GROUP BY user_id HAVING COUNT(*) > 20;

SELECT COUNT(*)
FROM sources
WHERE type = 'syslog' AND enabled = TRUE AND revoked_at IS NULL;

SELECT id, source, port, transport
FROM sources
WHERE type = 'syslog' AND enabled = TRUE
  AND (port IS NULL OR transport NOT IN ('udp', 'tcp', 'both', 'tls'));
```

The global count must be at most 500. Legacy syslog rows migrate disabled and must be reviewed and
explicitly enabled after deployment.

Pending/running export admission (substitute configured limits when not using defaults):

```sql
SELECT user_id, COUNT(*)
FROM export_jobs
WHERE status IN ('pending', 'running')
GROUP BY user_id HAVING COUNT(*) > 2;

SELECT COUNT(*) FROM export_jobs WHERE status IN ('pending', 'running');
```

The global count must be at most 10 by default. Disable/fail selected work explicitly if a limit is
exceeded; the migration never chooses records silently.

S3 inventory:

```sql
SELECT id, user_id, s3_endpoint, s3_bucket
FROM export_destinations
WHERE destination_type = 's3'
ORDER BY id;
```

Every endpoint must exactly appear in `WHISPERLOGS_S3_ALLOWED_HOSTS`; no scheme, path, wildcard,
port, trailing dot, or subdomain implication is accepted. Confirm every bucket satisfies the DNS
grammar in the operations reference. Configure the provider to abort incomplete multipart uploads
after seven days.

## 3. Configure secrets and runtime

- Mount a read-only `0600` bootstrap password file and set the bootstrap email to the desired
  administrator login. The recognized Calmbox legacy email is `local@localhost`; it is replaced
  with the configured bootstrap email during upgrade.
- Set `WHISPERLOGS_BIND_IP=0.0.0.0` inside a container while publishing only a loopback host port,
  unless a deliberate reverse proxy/network boundary exists.
- Set `WHISPERLOGS_EXPORT_ROOT` to persistent storage (for example
  `/var/lib/whisperlogs/exports`).
- Set the exact S3 hostname allowlist and the selected receiver/export/alert/syslog limits.
- Keep one process per database. Do not set `DNS_CLUSTER_QUERY`.

## 4. Migrate and stage

Run migrations once with the replacement artifact. On a staging clone, verify:

1. administrator login and forced reauthentication of old sessions;
2. anonymous rejection of protected routes and successful source-key ingestion;
3. local export and allowlisted multipart S3 export;
4. alert preview/evaluation and retention behavior;
5. reviewed syslog enablement, admission, and selected transport; and
6. the current bounded shipper's normal delivery and retry/drop behavior.

Any coordinated Serene shipper edit/deployment is a separate operation. Do not modify or deploy the
Serene checkout as part of the WhisperLogs-only step.

## 5. Promote and observe

Promote one digest-pinned WhisperLogs container/process. Verify login, ingestion continuity,
listener status, alert cycles, scheduler progress, retention, and the next daily S3 export. Keep the
stopped database backup until the new retention/export cycle has completed successfully.
