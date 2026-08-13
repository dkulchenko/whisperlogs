defmodule WhisperLogs.Repo.Migrations.UseCanonicalMetadataForSqliteFtsTriggers do
  use Ecto.Migration

  import WhisperLogs.MigrationHelpers

  def up do
    if sqlite?() do
      replace_triggers("coalesce(new.metadata, '{}')")
    end
  end

  def down do
    if sqlite?() do
      replace_triggers("coalesce(json(new.metadata), '{}')")
    end
  end

  defp replace_triggers(metadata_expression) do
    execute "DROP TRIGGER IF EXISTS logs_fts_after_update"
    execute "DROP TRIGGER IF EXISTS logs_fts_after_insert"

    execute """
    CREATE TRIGGER logs_fts_after_insert
    AFTER INSERT ON logs
    BEGIN
      INSERT INTO logs_fts(rowid, search_text)
      VALUES (new.id, new.message || char(10) || #{metadata_expression});
    END
    """

    execute """
    CREATE TRIGGER logs_fts_after_update
    AFTER UPDATE OF id, message, metadata ON logs
    BEGIN
      DELETE FROM logs_fts WHERE rowid = old.id;
      INSERT INTO logs_fts(rowid, search_text)
      VALUES (new.id, new.message || char(10) || #{metadata_expression});
    END
    """
  end
end
