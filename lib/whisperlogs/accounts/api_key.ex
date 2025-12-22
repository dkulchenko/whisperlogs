defmodule WhisperLogs.Accounts.ApiKey do
  @moduledoc """
  API key for authenticating log ingestion requests.

  Keys are hashed before storage (similar to passwords). The raw key
  is only shown once at creation time.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @rand_size 32
  @prefix "wl_"

  schema "api_keys" do
    field :name, :string
    field :source, :string
    field :key, :string, redact: true
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, WhisperLogs.Accounts.User, type: :id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new API key.
  """
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :source])
    |> validate_required([:name, :source])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:source, min: 1, max: 100)
    |> validate_format(:source, ~r/^[a-z0-9\-_]+$/,
      message: "must only contain lowercase letters, numbers, hyphens, and underscores"
    )
  end

  @doc """
  Generates a new API key string.
  """
  def generate_key do
    raw_bytes = :crypto.strong_rand_bytes(@rand_size)
    @prefix <> Base.url_encode64(raw_bytes, padding: false)
  end

  @doc """
  Returns true if the API key is active (not revoked).
  """
  def active?(%__MODULE__{revoked_at: nil}), do: true
  def active?(%__MODULE__{}), do: false
end
