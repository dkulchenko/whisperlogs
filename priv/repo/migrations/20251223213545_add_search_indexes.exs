defmodule WhisperLogs.Repo.Migrations.AddSearchIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS logs_message_trgm_idx
    ON logs USING GIN (message gin_trgm_ops)
    """

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS logs_metadata_text_trgm_idx
    ON logs USING GIN ((metadata::text) gin_trgm_ops)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS logs_message_trgm_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS logs_metadata_text_trgm_idx"
  end
end
