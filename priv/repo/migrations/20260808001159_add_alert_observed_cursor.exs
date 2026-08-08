defmodule WhisperLogs.Repo.Migrations.AddAlertObservedCursor do
  use Ecto.Migration

  def up do
    alter table(:alerts) do
      add :last_seen_inserted_at, :utc_datetime_usec
    end

    execute """
    UPDATE alerts
    SET last_seen_inserted_at = (
      SELECT inserted_at FROM logs WHERE logs.id = alerts.last_seen_log_id
    )
    WHERE last_seen_log_id IS NOT NULL
    """
  end

  def down, do: raise("forward-only migration")
end
