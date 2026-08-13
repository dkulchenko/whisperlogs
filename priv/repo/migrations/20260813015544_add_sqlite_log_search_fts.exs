defmodule WhisperLogs.Repo.Migrations.AddSqliteLogSearchFts do
  use Ecto.Migration

  import WhisperLogs.MigrationHelpers

  def up do
    if sqlite?() do
      execute """
      CREATE VIRTUAL TABLE logs_fts USING fts5(
        search_text,
        content='',
        contentless_delete=1,
        detail=none,
        tokenize='trigram'
      )
      """

      execute """
      INSERT INTO logs_fts(rowid, search_text)
      SELECT id, message || char(10) || coalesce(json(metadata), '{}')
      FROM logs
      """

      execute "INSERT INTO logs_fts(logs_fts) VALUES('optimize')"

      execute """
      CREATE TRIGGER logs_fts_after_insert
      AFTER INSERT ON logs
      BEGIN
        INSERT INTO logs_fts(rowid, search_text)
        VALUES (new.id, new.message || char(10) || coalesce(json(new.metadata), '{}'));
      END
      """

      execute """
      CREATE TRIGGER logs_fts_after_delete
      AFTER DELETE ON logs
      BEGIN
        DELETE FROM logs_fts WHERE rowid = old.id;
      END
      """

      execute """
      CREATE TRIGGER logs_fts_after_update
      AFTER UPDATE OF id, message, metadata ON logs
      BEGIN
        DELETE FROM logs_fts WHERE rowid = old.id;
        INSERT INTO logs_fts(rowid, search_text)
        VALUES (new.id, new.message || char(10) || coalesce(json(new.metadata), '{}'));
      END
      """
    end
  end

  def down do
    if sqlite?() do
      execute "DROP TRIGGER IF EXISTS logs_fts_after_update"
      execute "DROP TRIGGER IF EXISTS logs_fts_after_delete"
      execute "DROP TRIGGER IF EXISTS logs_fts_after_insert"
      execute "DROP TABLE IF EXISTS logs_fts"
    end
  end
end
