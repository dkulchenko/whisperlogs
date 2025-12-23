defmodule WhisperLogs.Repo.Migrations.DropRequestIdFromLogs do
  use Ecto.Migration

  def up do
    # Migrate existing request_id values into metadata
    execute """
    UPDATE logs
    SET metadata = jsonb_set(
      COALESCE(metadata, '{}'::jsonb),
      '{request_id}',
      to_jsonb(request_id)
    )
    WHERE request_id IS NOT NULL
    """

    alter table(:logs) do
      remove :request_id
    end
  end

  def down do
    alter table(:logs) do
      add :request_id, :string
    end

    # Migrate request_id back from metadata
    execute """
    UPDATE logs
    SET request_id = metadata->>'request_id'
    WHERE metadata->>'request_id' IS NOT NULL
    """
  end
end
