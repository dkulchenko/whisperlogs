defmodule WhisperLogs.Repo.Migrations.CreateAlertHistory do
  use Ecto.Migration
  import WhisperLogs.MigrationHelpers

  def change do
    create table(:alert_history) do
      add :alert_id, references(:alerts, on_delete: :delete_all), null: false
      add :trigger_type, :string, null: false
      add :trigger_data, :map, null: false, default: %{}

      # PostgreSQL supports native arrays of maps, SQLite uses JSON text
      if postgres?() do
        add :notifications_sent, {:array, :map}, default: []
      else
        add :notifications_sent, :string, default: "[]"
      end

      add :triggered_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:alert_history, [:alert_id])
    create index(:alert_history, [:triggered_at])
    create index(:alert_history, [:alert_id, :triggered_at])
  end
end
