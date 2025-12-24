defmodule WhisperLogs.Repo.Migrations.CreateAlerts do
  use Ecto.Migration
  import WhisperLogs.MigrationHelpers

  def change do
    create table(:alerts) do
      # In SQLite mode (single-user), user_id is not used
      if postgres?() do
        add :user_id, references(:users, on_delete: :delete_all), null: false
      else
        add :user_id, :integer
      end

      add :name, :string, null: false
      add :description, :string
      add :enabled, :boolean, default: true, null: false
      add :search_query, :string, null: false
      add :alert_type, :string, null: false

      # Velocity-specific settings (nullable for any_match type)
      add :velocity_threshold, :integer
      add :velocity_window_seconds, :integer

      # Cooldown to prevent notification spam
      add :cooldown_seconds, :integer, null: false, default: 300

      # State tracking
      add :last_seen_log_id, :bigint
      add :last_triggered_at, :utc_datetime
      add :last_checked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    if postgres?() do
      create index(:alerts, [:user_id])
      create index(:alerts, [:user_id, :enabled])
    end

    create index(:alerts, [:enabled])
  end
end
