defmodule WhisperLogs.Repo.Migrations.CreateAlertNotificationChannels do
  use Ecto.Migration

  def change do
    create table(:alert_notification_channels) do
      add :alert_id, references(:alerts, on_delete: :delete_all), null: false

      add :notification_channel_id, references(:notification_channels, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:alert_notification_channels, [:alert_id, :notification_channel_id])
    create index(:alert_notification_channels, [:notification_channel_id])
  end
end
