# Changelog

## v0.4.0 - 2026-05-30

- Add an offline SQLite-to-PostgreSQL production migration task with release scripts.
- Preserve migrated data, IDs, timestamps, admin login, export history, and PostgreSQL sequences.
- Run test coverage in both PostgreSQL and SQLite modes via `mix test.adapters`.
- Make `mix precommit` run both adapter suites.
- Improve syslog listener test port allocation for reliability.
