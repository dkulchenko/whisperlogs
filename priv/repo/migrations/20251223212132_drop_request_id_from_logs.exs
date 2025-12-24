defmodule WhisperLogs.Repo.Migrations.DropRequestIdFromLogs do
  use Ecto.Migration
  import WhisperLogs.MigrationHelpers

  def up do
    # SQLite can't DROP COLUMN when there's an index on it
    # Drop the index first
    if sqlite?() do
      execute "DROP INDEX IF EXISTS logs_request_id_index"
    end

    # Migrate existing request_id values into metadata
    if postgres?() do
      execute """
      UPDATE logs
      SET metadata = jsonb_set(
        COALESCE(metadata, '{}'::jsonb),
        '{request_id}',
        to_jsonb(request_id)
      )
      WHERE request_id IS NOT NULL
      """
    else
      execute """
      UPDATE logs
      SET metadata = json_set(
        COALESCE(metadata, '{}'),
        '$.request_id',
        request_id
      )
      WHERE request_id IS NOT NULL
      """
    end

    alter table(:logs) do
      remove :request_id
    end
  end

  def down do
    alter table(:logs) do
      add :request_id, :string
    end

    # Migrate request_id back from metadata
    if postgres?() do
      execute """
      UPDATE logs
      SET request_id = metadata->>'request_id'
      WHERE metadata->>'request_id' IS NOT NULL
      """
    else
      execute """
      UPDATE logs
      SET request_id = json_extract(metadata, '$.request_id')
      WHERE json_extract(metadata, '$.request_id') IS NOT NULL
      """
    end

    # Recreate the index (dropped in up for SQLite)
    if sqlite?() do
      create index(:logs, [:request_id], where: "request_id IS NOT NULL")
    end
  end
end
