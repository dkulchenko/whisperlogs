defmodule WhisperLogs.Accounts.Source do
  @moduledoc """
  Source configuration for log ingestion.

  Supports two types:
  - HTTP: Uses API key authentication (existing flow)
  - Syslog: Uses port-based UDP/TCP listeners
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @rand_size 32
  @prefix "wl_"

  @transports ~w(udp tcp both)

  schema "sources" do
    field :name, :string
    field :source, :string
    field :type, :string, default: "http"

    # HTTP-specific
    field :key, :string, redact: true

    # Syslog-specific
    field :port, :integer
    field :transport, :string
    field :allowed_hosts, {:array, :string}, default: []
    field :auto_register_hosts, :boolean, default: false

    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, WhisperLogs.Accounts.User, type: :id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating an HTTP source (API key based).
  """
  def http_changeset(source, attrs) do
    source
    |> cast(attrs, [:name, :source])
    |> put_change(:type, "http")
    |> validate_common()
  end

  @doc """
  Changeset for creating a syslog source.
  """
  def syslog_changeset(source, attrs) do
    source
    |> cast(attrs, [:name, :source, :port, :transport, :allowed_hosts, :auto_register_hosts])
    |> put_change(:type, "syslog")
    |> validate_common()
    |> validate_required([:port, :transport])
    |> validate_inclusion(:transport, @transports, message: "must be udp, tcp, or both")
    |> validate_number(:port, greater_than_or_equal_to: 1024, less_than_or_equal_to: 65535)
    |> unique_constraint(:port, name: :sources_port_active_index)
  end

  defp validate_common(changeset) do
    changeset
    |> validate_required([:name, :source])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:source, min: 1, max: 100)
    |> validate_format(:source, ~r/^[a-z0-9\-_]+$/,
      message: "must only contain lowercase letters, numbers, hyphens, and underscores"
    )
  end

  @doc """
  Generates a new API key string for HTTP sources.
  """
  def generate_key do
    raw_bytes = :crypto.strong_rand_bytes(@rand_size)
    @prefix <> Base.url_encode64(raw_bytes, padding: false)
  end

  @doc """
  Returns true if the source is active (not revoked).
  """
  def active?(%__MODULE__{revoked_at: nil}), do: true
  def active?(%__MODULE__{}), do: false

  @doc """
  Returns true if the source is an HTTP source.
  """
  def http?(%__MODULE__{type: "http"}), do: true
  def http?(%__MODULE__{}), do: false

  @doc """
  Returns true if the source is a syslog source.
  """
  def syslog?(%__MODULE__{type: "syslog"}), do: true
  def syslog?(%__MODULE__{}), do: false
end
