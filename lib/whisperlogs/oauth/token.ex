defmodule WhisperLogs.OAuth.Token do
  @moduledoc false

  use Ecto.Schema

  schema "oauth_tokens" do
    field :access_token_hash, :binary
    field :refresh_token_hash, :binary
    field :access_expires_at, :utc_datetime_usec
    field :refresh_expires_at, :utc_datetime_usec
    field :refresh_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :grant, WhisperLogs.OAuth.Grant

    timestamps(type: :utc_datetime_usec)
  end
end
