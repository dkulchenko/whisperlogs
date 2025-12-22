defmodule WhisperLogs.Repo.Migrations.AddKeyToApiKeys do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      add :key, :string
    end
  end
end
