defmodule WhisperLogs.OAuth.Grant do
  @moduledoc false

  use Ecto.Schema

  schema "oauth_grants" do
    field :client_id, :string
    field :client_key_hash, :binary
    field :client_name, :string
    field :redirect_uri, :string
    field :scope, :string
    field :resource, :string
    field :revoked_at, :utc_datetime_usec

    belongs_to :user, WhisperLogs.Accounts.User
    has_many :authorization_codes, WhisperLogs.OAuth.AuthorizationCode
    has_many :tokens, WhisperLogs.OAuth.Token

    timestamps(type: :utc_datetime_usec)
  end
end
