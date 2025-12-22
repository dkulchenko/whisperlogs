defmodule WhisperLogs.Repo.Migrations.CreateLogs do
  use Ecto.Migration

  def change do
    create table(:logs) do
      add :timestamp, :utc_datetime_usec, null: false
      add :level, :string, null: false
      add :message, :text, null: false
      add :metadata, :map, default: %{}
      add :request_id, :string
      add :source, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:logs, [:timestamp], comment: "Primary query pattern - most recent logs")
    create index(:logs, [:source])
    create index(:logs, [:level])
    create index(:logs, [:request_id], where: "request_id IS NOT NULL")
    create index(:logs, [:metadata], using: :gin)
  end
end
