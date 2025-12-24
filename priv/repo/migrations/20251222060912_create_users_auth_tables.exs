defmodule WhisperLogs.Repo.Migrations.CreateUsersAuthTables do
  use Ecto.Migration
  import WhisperLogs.MigrationHelpers

  def change do
    # PostgreSQL uses citext extension for case-insensitive email
    if postgres?() do
      execute "CREATE EXTENSION IF NOT EXISTS citext", ""
    end

    # Email type differs between adapters
    email_type = if postgres?(), do: :citext, else: :string

    create table(:users) do
      add :email, email_type, null: false
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])

    create table(:users_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])
  end
end
