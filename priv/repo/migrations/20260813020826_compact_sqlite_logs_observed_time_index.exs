defmodule WhisperLogs.Repo.Migrations.CompactSqliteLogsObservedTimeIndex do
  use Ecto.Migration

  import WhisperLogs.MigrationHelpers

  def up do
    if sqlite?() do
      drop index(:logs, [:inserted_at, :id], name: :logs_observed_time_index)
      create index(:logs, [:inserted_at], name: :logs_observed_time_index)
    end
  end

  def down do
    if sqlite?() do
      drop index(:logs, [:inserted_at], name: :logs_observed_time_index)
      create index(:logs, [:inserted_at, :id], name: :logs_observed_time_index)
    end
  end
end
