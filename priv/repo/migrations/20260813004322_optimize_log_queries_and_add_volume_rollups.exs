defmodule WhisperLogs.Repo.Migrations.OptimizeLogQueriesAndAddVolumeRollups do
  use Ecto.Migration

  import WhisperLogs.MigrationHelpers

  def up do
    if sqlite?() do
      execute """
      CREATE TABLE log_volume_rollups (
        granularity TEXT NOT NULL CHECK (granularity IN ('hour', 'day')),
        bucket_start TEXT NOT NULL,
        log_count INTEGER NOT NULL CHECK (log_count >= 0),
        byte_count INTEGER NOT NULL CHECK (byte_count >= 0)
      )
      """
    else
      create table(:log_volume_rollups, primary_key: false) do
        add :granularity, :string, null: false
        add :bucket_start, :utc_datetime_usec, null: false
        add :log_count, :bigint, null: false
        add :byte_count, :bigint, null: false
      end
    end

    create unique_index(:log_volume_rollups, [:granularity, :bucket_start],
             name: :log_volume_rollups_bucket_index
           )

    if postgres?() do
      create constraint(:log_volume_rollups, :log_volume_rollups_granularity_check,
               check: "granularity IN ('hour', 'day')"
             )

      create constraint(:log_volume_rollups, :log_volume_rollups_counts_check,
               check: "log_count >= 0 AND byte_count >= 0"
             )
    end

    if sqlite?() do
      create index(:logs, [:level, :inserted_at], name: :logs_level_observed_time_index)
      create index(:logs, [:source, :inserted_at], name: :logs_source_observed_time_index)
    else
      create index(:logs, [:level, :inserted_at, :id], name: :logs_level_observed_time_index)

      create index(:logs, [:source, :inserted_at, :id], name: :logs_source_observed_time_index)

      create index(:logs, [:timestamp, :id], name: :logs_event_time_index)
    end

    drop_if_exists index(:logs, [:level, :timestamp], name: :logs_level_timestamp_index)
    drop_if_exists index(:logs, [:source], name: :logs_source_index)

    if postgres?() do
      drop_if_exists index(:logs, [:timestamp], name: :logs_timestamp_index)
    end

    backfill_hourly_rollups()

    execute """
    INSERT INTO log_volume_rollups (granularity, bucket_start, log_count, byte_count)
    SELECT 'day',
           #{day_bucket_sql("bucket_start")},
           SUM(log_count),
           SUM(byte_count)
    FROM log_volume_rollups
    WHERE granularity = 'hour'
    GROUP BY #{day_bucket_sql("bucket_start")}
    """
  end

  def down do
    if sqlite?() do
      create index(:logs, [:level, :timestamp], name: :logs_level_timestamp_index)
      create index(:logs, [:source], name: :logs_source_index)
    else
      create index(:logs, [:level, :timestamp], name: :logs_level_timestamp_index)
      create index(:logs, [:source], name: :logs_source_index)
      create index(:logs, [:timestamp], name: :logs_timestamp_index)
      drop_if_exists index(:logs, [:timestamp, :id], name: :logs_event_time_index)
    end

    drop_if_exists index(:logs, [:level, :inserted_at], name: :logs_level_observed_time_index)

    drop_if_exists index(:logs, [:source, :inserted_at], name: :logs_source_observed_time_index)

    drop table(:log_volume_rollups)
  end

  defp backfill_hourly_rollups do
    execute """
    INSERT INTO log_volume_rollups (granularity, bucket_start, log_count, byte_count)
    SELECT 'hour',
           #{hour_bucket_sql("inserted_at")},
           COUNT(id),
           SUM(#{byte_size_sql()})
    FROM logs
    GROUP BY #{hour_bucket_sql("inserted_at")}
    """
  end

  defp hour_bucket_sql(column) do
    if sqlite?() do
      "strftime('%Y-%m-%dT%H:00:00.000000Z', #{column})"
    else
      "date_trunc('hour', #{column})"
    end
  end

  defp day_bucket_sql(column) do
    if sqlite?() do
      "strftime('%Y-%m-%dT00:00:00.000000Z', #{column})"
    else
      "date_trunc('day', #{column})"
    end
  end

  defp byte_size_sql do
    if sqlite?() do
      "length(CAST(message AS BLOB)) + length(CAST(coalesce(json(metadata), '{}') AS BLOB))"
    else
      "octet_length(message) + octet_length(coalesce(metadata::text, '{}'))"
    end
  end
end
