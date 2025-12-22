defmodule WhisperLogs.Repo.Migrations.RemoveKeyHashFromApiKeys do
  use Ecto.Migration

  def change do
    drop_if_exists index(:api_keys, [:key_hash])

    alter table(:api_keys) do
      remove :key_hash, :string
      remove :key_prefix, :string
    end

    create index(:api_keys, [:key])
  end
end
