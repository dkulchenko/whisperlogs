defmodule WhisperLogs.Repo.Migrations.CreateOauthGrantsAndTokens do
  use Ecto.Migration

  def change do
    create table(:oauth_grants) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :client_id, :text, null: false
      add :client_key_hash, :binary, null: false
      add :client_name, :string, null: false
      add :redirect_uri, :text, null: false
      add :scope, :string, null: false
      add :resource, :text, null: false
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:oauth_grants, [:user_id])
    create index(:oauth_grants, [:revoked_at])

    create unique_index(:oauth_grants, [:user_id, :client_key_hash])

    create table(:oauth_authorization_codes) do
      add :grant_id, references(:oauth_grants, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :redirect_uri, :text, null: false
      add :code_challenge, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:oauth_authorization_codes, [:grant_id])
    create unique_index(:oauth_authorization_codes, [:token_hash])

    create table(:oauth_tokens) do
      add :grant_id, references(:oauth_grants, on_delete: :delete_all), null: false
      add :access_token_hash, :binary, null: false
      add :refresh_token_hash, :binary, null: false
      add :access_expires_at, :utc_datetime_usec, null: false
      add :refresh_expires_at, :utc_datetime_usec, null: false
      add :refresh_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:oauth_tokens, [:grant_id])
    create unique_index(:oauth_tokens, [:access_token_hash])
    create unique_index(:oauth_tokens, [:refresh_token_hash])
  end
end
