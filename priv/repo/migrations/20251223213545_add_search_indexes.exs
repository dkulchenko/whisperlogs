defmodule WhisperLogs.Repo.Migrations.AddSearchIndexes do
  use Ecto.Migration
  import WhisperLogs.MigrationHelpers

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # GIN trigram indexes only available in PostgreSQL
    if postgres?() do
      execute """
      CREATE INDEX CONCURRENTLY IF NOT EXISTS logs_message_trgm_idx
      ON logs USING GIN (message gin_trgm_ops)
      """

      execute """
      CREATE INDEX CONCURRENTLY IF NOT EXISTS logs_metadata_text_trgm_idx
      ON logs USING GIN ((metadata::text) gin_trgm_ops)
      """
    end
  end

  def down do
    if postgres?() do
      execute "DROP INDEX CONCURRENTLY IF EXISTS logs_message_trgm_idx"
      execute "DROP INDEX CONCURRENTLY IF EXISTS logs_metadata_text_trgm_idx"
    end
  end
end
