defmodule WhisperLogs.SQLiteToPostgresMigrator do
  @moduledoc """
  Offline SQLite-to-PostgreSQL data migration.

  This module intentionally uses the concrete repo modules instead of the
  delegating `WhisperLogs.Repo`, because production migration runs with
  `DATABASE_URL` set and the delegating repo points at PostgreSQL.
  """

  alias Ecto.Adapters.SQL
  alias WhisperLogs.Accounts.{Bootstrap, Source, User, UserToken}
  alias WhisperLogs.Alerts.{Alert, AlertHistory, NotificationChannel}
  alias WhisperLogs.Exports.{ExportDestination, ExportJob}
  alias WhisperLogs.Logs.{Log, SavedSearch, VolumeRollups}
  alias WhisperLogs.OAuth.{AuthorizationCode, Grant, Token}
  alias WhisperLogs.Repo.{Postgres, SQLite}

  @default_batch_size 1_000

  @table_specs [
    %{
      table: "users",
      schema: User,
      columns: [
        :id,
        :email,
        :hashed_password,
        :inserted_at,
        :updated_at,
        :is_admin
      ],
      utc_datetime: [:inserted_at, :updated_at],
      booleans: [:is_admin]
    },
    %{
      table: "users_tokens",
      schema: UserToken,
      columns: [
        :id,
        :user_id,
        :token,
        :context,
        :sent_to,
        :authenticated_at,
        :inserted_at
      ],
      utc_datetime: [:authenticated_at, :inserted_at]
    },
    %{
      table: "oauth_grants",
      schema: Grant,
      columns: [
        :id,
        :user_id,
        :client_id,
        :client_key_hash,
        :client_name,
        :redirect_uri,
        :scope,
        :resource,
        :revoked_at,
        :inserted_at,
        :updated_at
      ],
      utc_datetime_usec: [:revoked_at, :inserted_at, :updated_at]
    },
    %{
      table: "oauth_authorization_codes",
      schema: AuthorizationCode,
      columns: [
        :id,
        :grant_id,
        :token_hash,
        :redirect_uri,
        :code_challenge,
        :expires_at,
        :used_at,
        :inserted_at
      ],
      utc_datetime_usec: [:expires_at, :used_at, :inserted_at]
    },
    %{
      table: "oauth_tokens",
      schema: Token,
      columns: [
        :id,
        :grant_id,
        :access_token_hash,
        :refresh_token_hash,
        :access_expires_at,
        :refresh_expires_at,
        :refresh_used_at,
        :revoked_at,
        :inserted_at,
        :updated_at
      ],
      utc_datetime_usec: [
        :access_expires_at,
        :refresh_expires_at,
        :refresh_used_at,
        :revoked_at,
        :inserted_at,
        :updated_at
      ]
    },
    %{
      table: "sources",
      schema: Source,
      columns: [
        :id,
        :user_id,
        :name,
        :source,
        :key,
        :revoked_at,
        :inserted_at,
        :updated_at,
        :type,
        :port,
        :transport,
        :allowed_hosts,
        :enabled,
        :admission_mode,
        :tls_framing,
        :tls_client_identities
      ],
      utc_datetime: [:revoked_at, :inserted_at, :updated_at],
      booleans: [:enabled],
      arrays: %{allowed_hosts: :string, tls_client_identities: :string}
    },
    %{
      table: "logs",
      schema: Log,
      columns: [:id, :timestamp, :level, :message, :metadata, :source, :inserted_at],
      utc_datetime_usec: [:timestamp, :inserted_at],
      maps: %{metadata: %{}}
    },
    %{
      table: "notification_channels",
      schema: NotificationChannel,
      columns: [
        :id,
        :user_id,
        :channel_type,
        :name,
        :enabled,
        :config,
        :inserted_at,
        :updated_at
      ],
      utc_datetime: [:inserted_at, :updated_at],
      booleans: [:enabled],
      maps: %{config: %{}},
      default_user_id?: true
    },
    %{
      table: "alerts",
      schema: Alert,
      columns: [
        :id,
        :user_id,
        :name,
        :description,
        :enabled,
        :search_query,
        :alert_type,
        :velocity_threshold,
        :velocity_window_seconds,
        :cooldown_seconds,
        :last_seen_log_id,
        :last_seen_inserted_at,
        :last_triggered_at,
        :last_checked_at,
        :inserted_at,
        :updated_at
      ],
      utc_datetime: [:last_triggered_at, :last_checked_at, :inserted_at, :updated_at],
      utc_datetime_usec: [:last_seen_inserted_at],
      booleans: [:enabled],
      default_user_id?: true
    },
    %{
      table: "alert_notification_channels",
      schema: "alert_notification_channels",
      columns: [:id, :alert_id, :notification_channel_id, :inserted_at, :updated_at],
      utc_datetime: [:inserted_at, :updated_at]
    },
    %{
      table: "alert_history",
      schema: AlertHistory,
      columns: [
        :id,
        :alert_id,
        :trigger_type,
        :trigger_data,
        :notifications_sent,
        :triggered_at,
        :inserted_at,
        :updated_at
      ],
      utc_datetime: [:triggered_at, :inserted_at, :updated_at],
      maps: %{trigger_data: %{}},
      arrays: %{notifications_sent: :map}
    },
    %{
      table: "export_destinations",
      schema: ExportDestination,
      columns: [
        :id,
        :user_id,
        :name,
        :destination_type,
        :enabled,
        :local_path,
        :s3_endpoint,
        :s3_bucket,
        :s3_region,
        :s3_access_key_id,
        :s3_secret_access_key,
        :s3_prefix,
        :auto_export_enabled,
        :auto_export_age_days,
        :inserted_at,
        :updated_at
      ],
      utc_datetime: [:inserted_at, :updated_at],
      booleans: [:enabled, :auto_export_enabled],
      default_user_id?: true
    },
    %{
      table: "export_jobs",
      schema: ExportJob,
      columns: [
        :id,
        :export_destination_id,
        :user_id,
        :status,
        :trigger,
        :from_timestamp,
        :to_timestamp,
        :file_name,
        :file_size_bytes,
        :log_count,
        :started_at,
        :completed_at,
        :error_message,
        :inserted_at,
        :updated_at
      ],
      utc_datetime: [:inserted_at, :updated_at],
      utc_datetime_usec: [:from_timestamp, :to_timestamp, :started_at, :completed_at],
      default_user_id?: true
    },
    %{
      table: "saved_searches",
      schema: SavedSearch,
      columns: [
        :id,
        :user_id,
        :name,
        :search,
        :source,
        :levels,
        :time_range,
        :inserted_at,
        :updated_at
      ],
      utc_datetime: [:inserted_at, :updated_at],
      default_user_id?: true
    }
  ]

  @sequence_tables ~w(
    users
    users_tokens
    oauth_grants
    oauth_authorization_codes
    oauth_tokens
    logs
    notification_channels
    alerts
    alert_notification_channels
    alert_history
    export_destinations
    export_jobs
    saved_searches
  )

  @app :whisperlogs

  def migrate(opts \\ []) do
    load_app()

    source_path = source_path!(opts)
    batch_size = batch_size(opts)
    allow_non_empty? = allow_non_empty_target?(opts)

    configure_sqlite!(source_path)
    validate_source_file!(source_path)

    {:ok, report, _apps} =
      Ecto.Migrator.with_repo(SQLite, fn sqlite_repo ->
        {:ok, result, _apps} =
          Ecto.Migrator.with_repo(Postgres, fn postgres_repo ->
            run_target_migrations(postgres_repo)
            assert_current_source_migrations!(sqlite_repo)
            assert_empty_target!(postgres_repo, allow_non_empty?)

            admin_context = admin_context!(sqlite_repo, opts)
            target_counts_before = target_counts(postgres_repo)

            context = Map.put(admin_context, :target_counts_before, target_counts_before)

            copy_tables(sqlite_repo, postgres_repo, batch_size, context)
            VolumeRollups.rebuild!(postgres_repo)
            reset_sequences!(postgres_repo)
            verify_counts!(sqlite_repo, postgres_repo, context)
          end)

        result
      end)

    if Keyword.get(opts, :print_report?, true) do
      print_report(report)
    end

    {:ok, report}
  end

  def normalize_map(nil, default), do: default
  def normalize_map(value, _default) when is_map(value), do: value

  def normalize_map(value, default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, nil} -> default
      _ -> raise ArgumentError, "expected JSON object, got: #{inspect(value)}"
    end
  end

  def normalize_array(nil, _type), do: []

  def normalize_array(value, type) when is_binary(value),
    do: value |> decode_json_array!() |> normalize_array(type)

  def normalize_array(value, :string) when is_list(value) do
    Enum.map(value, fn
      item when is_binary(item) -> item
      item -> to_string(item)
    end)
  end

  def normalize_array(value, :map) when is_list(value) do
    Enum.map(value, fn
      item when is_map(item) -> item
      item -> raise ArgumentError, "expected map array item, got: #{inspect(item)}"
    end)
  end

  def normalize_array(value, type),
    do: raise(ArgumentError, "expected #{type} array, got: #{inspect(value)}")

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end

  defp source_path!(opts) do
    Keyword.get(opts, :source_path) ||
      System.get_env("SQLITE_DATABASE_PATH") ||
      System.get_env("DATABASE_PATH") ||
      raise ArgumentError,
            "SQLITE_DATABASE_PATH is required when DATABASE_PATH is not set"
  end

  defp batch_size(opts) do
    value =
      Keyword.get(opts, :batch_size) || System.get_env("MIGRATION_BATCH_SIZE") ||
        @default_batch_size

    value = if is_binary(value), do: String.to_integer(value), else: value

    if value > 0 do
      value
    else
      raise ArgumentError, "MIGRATION_BATCH_SIZE must be greater than zero"
    end
  end

  defp allow_non_empty_target?(opts) do
    Keyword.get(opts, :allow_non_empty_target?, false) ||
      System.get_env("MIGRATION_ALLOW_NON_EMPTY_TARGET") in ~w(true 1 yes)
  end

  defp configure_sqlite!(source_path) do
    config =
      SQLite.config()
      |> Keyword.put(:database, source_path)
      |> Keyword.put_new(:pool_size, 1)
      |> Keyword.put_new(:journal_mode, :wal)
      |> Keyword.put_new(:busy_timeout, 5_000)
      |> Keyword.put_new(:synchronous, :normal)
      |> Keyword.put_new(:cache_size, -64_000)
      |> Keyword.put_new(:temp_store, :memory)

    config =
      Keyword.put(config, :load_extensions, [WhisperLogs.SQLean.verified_extension_path!()])

    Application.put_env(@app, SQLite, config)
  end

  defp validate_source_file!(source_path) do
    unless File.regular?(source_path) do
      raise ArgumentError, "SQLite source database does not exist: #{source_path}"
    end
  end

  defp run_target_migrations(repo) do
    Ecto.Migrator.run(repo, :up, all: true)
  end

  defp assert_current_source_migrations!(repo) do
    expected_versions = migration_versions()
    source_versions = schema_migration_versions(repo)

    if MapSet.equal?(expected_versions, source_versions) do
      :ok
    else
      missing =
        MapSet.difference(expected_versions, source_versions) |> MapSet.to_list() |> Enum.sort()

      extra =
        MapSet.difference(source_versions, expected_versions) |> MapSet.to_list() |> Enum.sort()

      raise """
      SQLite source migration versions do not match this release.
      Missing versions: #{inspect(missing)}
      Extra versions: #{inspect(extra)}
      """
    end
  end

  defp migration_versions do
    migrations_path = Path.join(:code.priv_dir(@app) |> to_string(), "repo/migrations")

    migrations_path
    |> File.ls!()
    |> Enum.flat_map(fn filename ->
      case Regex.run(~r/^(\d+)_.*\.exs$/, filename) do
        [_, version] -> [String.to_integer(version)]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp schema_migration_versions(repo) do
    case SQL.query(repo, "SELECT version FROM schema_migrations", [], timeout: :infinity) do
      {:ok, %{rows: rows}} ->
        rows |> Enum.map(fn [version] -> parse_version(version) end) |> MapSet.new()

      {:error, error} ->
        raise "Failed to read SQLite schema_migrations: #{Exception.message(error)}"
    end
  end

  defp parse_version(version) when is_integer(version), do: version
  defp parse_version(version) when is_binary(version), do: String.to_integer(version)

  defp assert_empty_target!(_repo, true), do: :ok

  defp assert_empty_target!(repo, false) do
    non_empty =
      @table_specs
      |> Enum.map(& &1.table)
      |> Enum.filter(&(count_rows(repo, &1) > 0))

    if non_empty == [] do
      :ok
    else
      raise ArgumentError,
            "PostgreSQL target already contains data in: #{Enum.join(non_empty, ", ")}"
    end
  end

  defp admin_context!(repo, opts) do
    rows =
      SQL.query!(repo, "SELECT id, email, hashed_password, is_admin FROM users ORDER BY id", [],
        timeout: :infinity
      ).rows

    admins = Enum.filter(rows, fn [_id, _email, _password, admin] -> normalize_boolean(admin) end)

    case {rows, admins} do
      {[[id, "local@localhost", nil, _]], [[id, "local@localhost", nil, _]]} ->
        email_opts =
          case Keyword.fetch(opts, :bootstrap_admin_email) do
            {:ok, email} -> [email: email]
            :error -> []
          end

        email = Bootstrap.admin_email!(email_opts)

        path =
          Keyword.get(opts, :bootstrap_admin_password_file) ||
            System.get_env("WHISPERLOGS_BOOTSTRAP_ADMIN_PASSWORD_FILE")

        password = Bootstrap.read_password_file!(path)
        %{admin_user_id: id, admin_email: email, admin_password_hash: password_hash!(password)}

      {_users, [[id, _email, password, _]]} when is_binary(password) ->
        %{admin_user_id: id, admin_email: nil, admin_password_hash: nil}

      _ ->
        raise ArgumentError, "SQLite source does not satisfy the bootstrap administrator contract"
    end
  end

  defp copy_tables(sqlite_repo, postgres_repo, batch_size, context) do
    Enum.map(@table_specs, fn spec ->
      copied = copy_table(sqlite_repo, postgres_repo, spec, batch_size, context)
      {spec.table, copied}
    end)
  end

  defp copy_table(sqlite_repo, postgres_repo, spec, batch_size, context) do
    spec
    |> stream_source_batches(sqlite_repo, batch_size)
    |> Enum.reduce(0, fn rows, total ->
      entries = Enum.map(rows, &normalize_row(&1, spec, context))

      if entries != [] do
        {_count, _} = postgres_repo.insert_all(spec.schema, entries, timeout: :infinity)
      end

      total + length(entries)
    end)
  end

  defp stream_source_batches(spec, repo, batch_size) do
    Stream.unfold(0, fn offset ->
      rows = select_batch(repo, spec, batch_size, offset)

      if rows == [] do
        nil
      else
        {rows, offset + batch_size}
      end
    end)
  end

  defp select_batch(repo, spec, limit, offset) do
    columns = spec.columns
    column_sql = columns |> Enum.map(&quote_identifier/1) |> Enum.join(", ")

    sql =
      "SELECT #{column_sql} FROM #{quote_identifier(spec.table)} ORDER BY id LIMIT ? OFFSET ?"

    result = SQL.query!(repo, sql, [limit, offset], timeout: :infinity)

    Enum.map(result.rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new()
    end)
  end

  defp normalize_row(row, spec, context) do
    row
    |> normalize_datetimes(spec)
    |> normalize_booleans(spec)
    |> normalize_maps(spec)
    |> normalize_arrays(spec)
    |> maybe_default_user_id(spec, context)
    |> maybe_update_admin_user(spec, context)
  end

  defp normalize_datetimes(row, spec) do
    row =
      spec
      |> Map.get(:utc_datetime, [])
      |> Enum.reduce(row, fn column, row ->
        Map.update!(row, column, &normalize_datetime(&1, :second))
      end)

    spec
    |> Map.get(:utc_datetime_usec, [])
    |> Enum.reduce(row, fn column, row ->
      Map.update!(row, column, &normalize_datetime(&1, :microsecond))
    end)
  end

  defp normalize_datetime(nil, _precision), do: nil
  defp normalize_datetime(%DateTime{} = value, :second), do: DateTime.truncate(value, :second)
  defp normalize_datetime(%DateTime{} = value, :microsecond), do: value

  defp normalize_datetime(%NaiveDateTime{} = value, precision) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> normalize_datetime(precision)
  end

  defp normalize_datetime(value, precision) when is_binary(value) do
    value
    |> parse_datetime!()
    |> normalize_datetime(precision)
  end

  defp parse_datetime!(value) do
    value = String.trim(value)

    candidates =
      [value, String.replace(value, " ", "T")]
      |> Enum.flat_map(fn candidate ->
        if String.ends_with?(candidate, "Z") or String.match?(candidate, ~r/[+-]\d\d:\d\d$/) do
          [candidate]
        else
          [candidate, candidate <> "Z"]
        end
      end)

    Enum.find_value(candidates, fn candidate ->
      case DateTime.from_iso8601(candidate) do
        {:ok, datetime, _offset} -> datetime
        {:error, _reason} -> nil
      end
    end) || raise ArgumentError, "could not parse datetime: #{inspect(value)}"
  end

  defp normalize_booleans(row, spec) do
    spec
    |> Map.get(:booleans, [])
    |> Enum.reduce(row, fn column, row ->
      Map.update!(row, column, &normalize_boolean/1)
    end)
  end

  defp normalize_boolean(nil), do: nil
  defp normalize_boolean(value) when is_boolean(value), do: value
  defp normalize_boolean(value) when is_integer(value), do: value != 0
  defp normalize_boolean("0"), do: false
  defp normalize_boolean("1"), do: true
  defp normalize_boolean("false"), do: false
  defp normalize_boolean("true"), do: true

  defp normalize_maps(row, spec) do
    spec
    |> Map.get(:maps, %{})
    |> Enum.reduce(row, fn {column, default}, row ->
      Map.update!(row, column, &normalize_map(&1, default))
    end)
  end

  defp normalize_arrays(row, spec) do
    spec
    |> Map.get(:arrays, %{})
    |> Enum.reduce(row, fn {column, type}, row ->
      Map.update!(row, column, &normalize_array(&1, type))
    end)
  end

  defp decode_json_array!(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> decoded
      {:ok, nil} -> []
      _ -> raise ArgumentError, "expected JSON array, got: #{inspect(value)}"
    end
  end

  defp maybe_default_user_id(row, %{default_user_id?: true}, %{admin_user_id: admin_user_id}) do
    if is_nil(row.user_id), do: %{row | user_id: admin_user_id}, else: row
  end

  defp maybe_default_user_id(row, _spec, _context), do: row

  defp maybe_update_admin_user(%{id: id} = row, %{table: "users"}, %{
         admin_user_id: id,
         admin_email: admin_email,
         admin_password_hash: admin_password_hash
       }) do
    if admin_password_hash do
      row
      |> Map.put(:email, admin_email)
      |> Map.put(:hashed_password, admin_password_hash)
      |> Map.put(:is_admin, true)
    else
      row
    end
  end

  defp maybe_update_admin_user(row, _spec, _context), do: row

  defp password_hash!(password) do
    changeset =
      User.password_changeset(%User{}, %{
        "password" => password,
        "password_confirmation" => password
      })

    if changeset.valid? do
      Ecto.Changeset.get_change(changeset, :hashed_password)
    else
      raise ArgumentError, "bootstrap administrator password does not satisfy password policy"
    end
  end

  defp reset_sequences!(repo) do
    Enum.each(@sequence_tables, fn table ->
      sql = """
      SELECT setval(
        pg_get_serial_sequence($1, 'id'),
        COALESCE((SELECT MAX(id) FROM #{quote_identifier(table)}), 1),
        (SELECT COUNT(*) FROM #{quote_identifier(table)}) > 0
      )
      """

      SQL.query!(repo, sql, [table], timeout: :infinity)
    end)
  end

  defp verify_counts!(sqlite_repo, postgres_repo, %{target_counts_before: target_counts_before}) do
    Enum.map(@table_specs, fn spec ->
      source_count = count_rows(sqlite_repo, spec.table)
      target_count_before = Map.fetch!(target_counts_before, spec.table)
      target_count = count_rows(postgres_repo, spec.table)
      expected_count = target_count_before + source_count

      if expected_count != target_count do
        raise """
        Row count mismatch for #{spec.table}.
        SQLite source: #{source_count}
        PostgreSQL target before: #{target_count_before}
        PostgreSQL target: #{target_count}
        Expected target: #{expected_count}
        """
      end

      %{
        table: spec.table,
        source_count: source_count,
        target_count_before: target_count_before,
        target_count: target_count
      }
    end)
  end

  defp target_counts(repo) do
    @table_specs
    |> Enum.map(fn spec -> {spec.table, count_rows(repo, spec.table)} end)
    |> Map.new()
  end

  defp count_rows(repo, table) do
    repo
    |> SQL.query!("SELECT COUNT(*) FROM #{quote_identifier(table)}", [], timeout: :infinity)
    |> Map.fetch!(:rows)
    |> hd()
    |> hd()
  end

  defp print_report(report) do
    IO.puts("SQLite to PostgreSQL migration completed.")

    Enum.each(report, fn %{
                           table: table,
                           source_count: source_count,
                           target_count_before: target_count_before,
                           target_count: target_count
                         } ->
      IO.puts("#{table}: +#{source_count} (#{target_count_before} -> #{target_count})")
    end)
  end

  defp quote_identifier(identifier) when is_atom(identifier),
    do: quote_identifier(Atom.to_string(identifier))

  defp quote_identifier(identifier) when is_binary(identifier) do
    "\"" <> String.replace(identifier, "\"", "\"\"") <> "\""
  end
end
