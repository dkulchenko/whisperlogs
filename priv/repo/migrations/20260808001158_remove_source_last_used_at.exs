defmodule WhisperLogs.Repo.Migrations.RemoveSourceLastUsedAt do
  use Ecto.Migration

  def up do
    alter table(:sources) do
      remove :last_used_at
    end
  end

  def down, do: raise("forward-only migration")
end
