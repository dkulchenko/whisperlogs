defmodule WhisperLogs.Repo.Migrations.RemoveAutoRegisterHosts do
  use Ecto.Migration

  def up do
    alter table(:sources) do
      remove :auto_register_hosts
    end
  end

  def down, do: raise("forward-only migration")
end
