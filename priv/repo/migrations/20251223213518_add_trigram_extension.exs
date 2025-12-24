defmodule WhisperLogs.Repo.Migrations.AddTrigramExtension do
  use Ecto.Migration
  import WhisperLogs.MigrationHelpers

  def up do
    # pg_trgm extension only available in PostgreSQL
    if postgres?() do
      execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"
    end
  end

  def down do
    if postgres?() do
      execute "DROP EXTENSION IF EXISTS pg_trgm"
    end
  end
end
