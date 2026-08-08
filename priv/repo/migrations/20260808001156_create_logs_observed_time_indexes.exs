defmodule WhisperLogs.Repo.Migrations.CreateLogsObservedTimeIndexes do
  use Ecto.Migration

  def change do
    create index(:logs, [:inserted_at, :id], name: :logs_observed_time_index)
  end
end
