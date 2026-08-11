defmodule WhisperLogs.OAuth.AuthorizationCode do
  @moduledoc false

  use Ecto.Schema

  schema "oauth_authorization_codes" do
    field :token_hash, :binary
    field :redirect_uri, :string
    field :code_challenge, :string
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    belongs_to :grant, WhisperLogs.OAuth.Grant

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
