defmodule WhisperLogs.Repo.Migrations.RemoveUnusedIdentityState do
  use Ecto.Migration

  def up do
    execute "DELETE FROM users_tokens WHERE context = 'session'"

    alter table(:notification_channels) do
      remove :verified_at
    end

    alter table(:users) do
      remove :confirmed_at
    end
  end

  def down, do: raise("forward-only migration")
end
