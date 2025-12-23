defmodule WhisperLogs.Repo.Migrations.CreateNotificationChannels do
  use Ecto.Migration

  def change do
    create table(:notification_channels) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :channel_type, :string, null: false
      add :name, :string, null: false
      add :enabled, :boolean, default: true, null: false
      add :config, :map, null: false, default: %{}
      add :verified_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:notification_channels, [:user_id])
    create unique_index(:notification_channels, [:user_id, :channel_type, :name])
  end
end
