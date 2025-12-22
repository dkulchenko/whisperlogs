defmodule WhisperLogs.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :source, :string, null: false
      add :key_prefix, :string, null: false
      add :key_hash, :string, null: false
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:api_keys, [:user_id])
    create index(:api_keys, [:key_hash])

    create unique_index(:api_keys, [:user_id, :source],
             where: "revoked_at IS NULL",
             name: :api_keys_user_id_source_active_index
           )
  end
end
