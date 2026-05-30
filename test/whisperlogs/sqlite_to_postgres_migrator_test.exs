defmodule WhisperLogs.SQLiteToPostgresMigratorTest do
  use ExUnit.Case, async: false

  @moduletag :postgres_only

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias WhisperLogs.Accounts.{Source, User}
  alias WhisperLogs.Alerts.{Alert, AlertHistory, NotificationChannel}
  alias WhisperLogs.Exports.{ExportDestination, ExportJob}
  alias WhisperLogs.Logs.{Log, SavedSearch}
  alias WhisperLogs.Repo.{Postgres, SQLite}
  alias WhisperLogs.SQLiteToPostgresMigrator
  alias WhisperLogs.{Accounts, Exports}

  @admin_email "admin@example.com"
  @admin_password "correct horse battery staple"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Postgres, shared: true)

    old_adapter = Application.get_env(:whisperlogs, :db_adapter)
    old_sqlite_config = Application.get_env(:whisperlogs, SQLite)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
      Application.put_env(:whisperlogs, :db_adapter, old_adapter)
      Application.put_env(:whisperlogs, SQLite, old_sqlite_config)
    end)

    :ok
  end

  describe "conversion helpers" do
    test "normalizes JSON-string arrays and maps" do
      assert SQLiteToPostgresMigrator.normalize_array(~s(["127.0.0.1", "10.0.0.1"]), :string) ==
               ["127.0.0.1", "10.0.0.1"]

      assert SQLiteToPostgresMigrator.normalize_array(
               ~s([{"type":"email","status":"sent"}]),
               :map
             ) == [%{"type" => "email", "status" => "sent"}]

      assert SQLiteToPostgresMigrator.normalize_map(~s({"request_id":"abc"}), %{}) == %{
               "request_id" => "abc"
             }
    end

    test "rejects invalid array and map JSON" do
      assert_raise ArgumentError, fn ->
        SQLiteToPostgresMigrator.normalize_array(~s({"not":"array"}), :string)
      end

      assert_raise ArgumentError, fn ->
        SQLiteToPostgresMigrator.normalize_map(~s(["not", "map"]), %{})
      end
    end
  end

  test "migrates a representative SQLite database into PostgreSQL" do
    sqlite_path = prepare_sqlite_source!()

    assert {:ok, report} =
             SQLiteToPostgresMigrator.migrate(
               source_path: sqlite_path,
               admin_email: @admin_email,
               admin_password: @admin_password,
               batch_size: 2,
               print_report?: false
             )

    assert Enum.find(report, &(&1.table == "logs")).target_count == 2

    user = Postgres.one!(from u in User, where: u.id == 1)
    assert user.email == @admin_email
    assert user.is_admin
    assert User.valid_password?(user, @admin_password)

    syslog_source = Postgres.get_by!(Source, source: "syslog-main")
    assert syslog_source.allowed_hosts == ["127.0.0.1", "10.0.0.2"]
    assert syslog_source.auto_register_hosts

    log = Postgres.get!(Log, 11)
    assert log.metadata == %{"request_id" => "req-1", "duration_ms" => 12.5}

    channel = Postgres.get!(NotificationChannel, 21)
    assert channel.user_id == user.id
    assert channel.config == %{"email" => "ops@example.com"}

    alert = Postgres.get!(Alert, 31)
    assert alert.user_id == user.id
    assert alert.last_seen_log_id == 11

    history = Postgres.get!(AlertHistory, 51)

    assert history.notifications_sent == [
             %{"type" => "email", "status" => "sent", "channel_id" => 21}
           ]

    destination = Postgres.get!(ExportDestination, 61)
    assert destination.user_id == user.id

    job = Postgres.get!(ExportJob, 71)
    assert job.export_destination_id == destination.id
    assert job.user_id == user.id
    assert [%ExportJob{id: 71}] = Exports.list_export_jobs(Accounts.Scope.for_user(user))

    saved_search = Postgres.get!(SavedSearch, 81)
    assert saved_search.user_id == user.id

    inserted =
      Postgres.insert!(%Log{
        timestamp: DateTime.utc_now(),
        level: "info",
        message: "sequence check",
        metadata: %{},
        source: "api"
      })

    assert inserted.id > 12
  end

  test "refuses to migrate into a non-empty target by default" do
    sqlite_path = prepare_sqlite_source!()

    Postgres.insert!(%Log{
      timestamp: DateTime.utc_now(),
      level: "info",
      message: "existing target row",
      metadata: %{},
      source: "existing"
    })

    assert_raise ArgumentError, ~r/PostgreSQL target already contains data/, fn ->
      SQLiteToPostgresMigrator.migrate(
        source_path: sqlite_path,
        admin_email: @admin_email,
        admin_password: @admin_password,
        print_report?: false
      )
    end
  end

  test "accounts for existing rows when non-empty targets are allowed" do
    sqlite_path = prepare_sqlite_source!()

    existing_log =
      Postgres.insert!(%Log{
        timestamp: DateTime.utc_now(),
        level: "info",
        message: "existing target row",
        metadata: %{},
        source: "existing"
      })

    assert {:ok, report} =
             SQLiteToPostgresMigrator.migrate(
               source_path: sqlite_path,
               admin_email: @admin_email,
               admin_password: @admin_password,
               allow_non_empty_target?: true,
               print_report?: false
             )

    logs_report = Enum.find(report, &(&1.table == "logs"))
    assert logs_report.source_count == 2
    assert logs_report.target_count_before == 1
    assert logs_report.target_count == 3
    assert Postgres.get!(Log, existing_log.id).message == "existing target row"
  end

  test "requires admin credentials and an existing source file" do
    assert_raise ArgumentError, ~r/ADMIN_EMAIL is required/, fn ->
      SQLiteToPostgresMigrator.migrate(
        source_path: "/tmp/does-not-matter.sqlite",
        admin_password: @admin_password,
        print_report?: false
      )
    end

    assert_raise ArgumentError, ~r/SQLite source database does not exist/, fn ->
      SQLiteToPostgresMigrator.migrate(
        source_path: "/tmp/missing-whisperlogs.sqlite",
        admin_email: @admin_email,
        admin_password: @admin_password,
        print_report?: false
      )
    end
  end

  defp prepare_sqlite_source! do
    path =
      Path.join(
        System.tmp_dir!(),
        "whisperlogs-migration-#{System.unique_integer([:positive])}.db"
      )

    File.rm(path)
    File.rm(path <> "-shm")
    File.rm(path <> "-wal")

    configure_sqlite!(path)

    old_adapter = Application.get_env(:whisperlogs, :db_adapter)
    old_compiler_options = Code.compiler_options()
    Application.put_env(:whisperlogs, :db_adapter, :sqlite)
    Code.compiler_options(ignore_module_conflict: true)

    try do
      WhisperLogs.Release.create_and_migrate()

      {:ok, _, _} =
        Ecto.Migrator.with_repo(SQLite, fn repo ->
          seed_sqlite!(repo)
        end)
    after
      Application.put_env(:whisperlogs, :db_adapter, old_adapter)
      Code.compiler_options(old_compiler_options)
    end

    path
  end

  defp configure_sqlite!(path) do
    config =
      SQLite.config()
      |> Keyword.put(:database, path)
      |> Keyword.put(:pool_size, 1)
      |> Keyword.put(:journal_mode, :wal)
      |> Keyword.put(:busy_timeout, 5_000)
      |> Keyword.put(:synchronous, :normal)
      |> Keyword.put(:cache_size, -64_000)
      |> Keyword.put(:temp_store, :memory)

    Application.put_env(:whisperlogs, SQLite, config)
  end

  defp seed_sqlite!(repo) do
    now = "2026-05-30T12:00:00Z"
    source_id = Ecto.UUID.generate()
    syslog_source_id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO users_tokens
        (id, user_id, token, context, sent_to, authenticated_at, inserted_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [101, 1, <<1, 2, 3>>, "session", nil, now, now]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO sources
        (id, user_id, name, source, key, last_used_at, revoked_at, inserted_at, updated_at,
         type, port, transport, allowed_hosts, auto_register_hosts)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        source_id,
        1,
        "HTTP API",
        "api",
        "wl_test",
        now,
        nil,
        now,
        now,
        "http",
        nil,
        nil,
        "[]",
        0
      ]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO sources
        (id, user_id, name, source, key, last_used_at, revoked_at, inserted_at, updated_at,
         type, port, transport, allowed_hosts, auto_register_hosts)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        syslog_source_id,
        1,
        "Syslog",
        "syslog-main",
        nil,
        nil,
        nil,
        now,
        now,
        "syslog",
        5514,
        "udp",
        ~s(["127.0.0.1","10.0.0.2"]),
        1
      ]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO logs (id, timestamp, level, message, metadata, source, inserted_at)
      VALUES (?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?)
      """,
      [
        11,
        "2026-05-30T12:01:00.123456Z",
        "error",
        "first log",
        ~s({"request_id":"req-1","duration_ms":12.5}),
        "api",
        "2026-05-30T12:01:00.123456Z",
        12,
        "2026-05-30T12:02:00.654321Z",
        "info",
        "second log",
        "{}",
        "syslog-main",
        "2026-05-30T12:02:00.654321Z"
      ]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO notification_channels
        (id, user_id, channel_type, name, enabled, config, verified_at, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [21, nil, "email", "Ops", 1, ~s({"email":"ops@example.com"}), now, now, now]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO alerts
        (id, user_id, name, description, enabled, search_query, alert_type,
         velocity_threshold, velocity_window_seconds, cooldown_seconds,
         last_seen_log_id, last_triggered_at, last_checked_at, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        31,
        nil,
        "Errors",
        "Error alert",
        1,
        "level:error",
        "any_match",
        nil,
        nil,
        300,
        11,
        now,
        now,
        now,
        now
      ]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO alert_notification_channels
        (id, alert_id, notification_channel_id, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?)
      """,
      [41, 31, 21, now, now]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO alert_history
        (id, alert_id, trigger_type, trigger_data, notifications_sent,
         triggered_at, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        51,
        31,
        "any_match",
        ~s({"log_id":11}),
        ~s([{"type":"email","status":"sent","channel_id":21}]),
        now,
        now,
        now
      ]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO export_destinations
        (id, user_id, name, destination_type, enabled, local_path,
         s3_endpoint, s3_bucket, s3_region, s3_access_key_id, s3_secret_access_key, s3_prefix,
         auto_export_enabled, auto_export_age_days, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        61,
        nil,
        "Local",
        "local",
        1,
        "/tmp/exports",
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
        0,
        nil,
        now,
        now
      ]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO export_jobs
        (id, export_destination_id, user_id, status, trigger, from_timestamp, to_timestamp,
         file_name, file_size_bytes, log_count, started_at, completed_at, error_message,
         inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        71,
        61,
        nil,
        "completed",
        "manual",
        "2026-05-29T12:00:00.000000Z",
        "2026-05-30T12:00:00.000000Z",
        "export.jsonl.gz",
        1234,
        2,
        "2026-05-30T12:03:00.000000Z",
        "2026-05-30T12:04:00.000000Z",
        nil,
        now,
        now
      ]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO saved_searches
        (id, user_id, name, search, source, levels, time_range, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [81, 1, "Errors", "level:error", "api", "error,warning", "24h", now, now]
    )
  end
end
