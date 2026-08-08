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

  @transports ~w(udp tcp both tls)
  @admission_modes ~w(allowlist any)
  @tls_framings ~w(octet_counted newline)

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
    field :enabled, :boolean, default: true
    field :admission_mode, :string, default: "allowlist"
    field :tls_framing, :string
    field :tls_client_identities, {:array, :string}, default: []

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
    |> cast(attrs, [
      :name,
      :source,
      :port,
      :transport,
      :allowed_hosts,
      :admission_mode,
      :tls_framing,
      :tls_client_identities
    ])
    |> put_change(:type, "syslog")
    |> validate_common()
    |> validate_required([:port, :transport])
    |> validate_inclusion(:transport, @transports)
    |> validate_inclusion(:admission_mode, @admission_modes)
    |> validate_number(:port, greater_than_or_equal_to: 1024, less_than_or_equal_to: 65535)
    |> normalize_allowed_hosts()
    |> validate_tls()
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

  @doc """
  Changeset for updating an HTTP source (name only).
  """
  def update_http_changeset(source, attrs) do
    source
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
  end

  @doc """
  Changeset for updating a syslog source.
  Fields: name, port, transport, admission mode, hosts, and TLS identity policy.
  """
  def update_syslog_changeset(source, attrs) do
    source
    |> cast(attrs, [
      :name,
      :port,
      :transport,
      :allowed_hosts,
      :admission_mode,
      :tls_framing,
      :tls_client_identities
    ])
    |> validate_required([:name, :port, :transport])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_inclusion(:transport, @transports)
    |> validate_inclusion(:admission_mode, @admission_modes)
    |> validate_number(:port, greater_than_or_equal_to: 1024, less_than_or_equal_to: 65535)
    |> normalize_allowed_hosts()
    |> validate_tls()
    |> unique_constraint(:port, name: :sources_port_active_index)
  end

  @doc "Validates every persisted syslog policy field before listener activation."
  def persisted_syslog_changeset(%__MODULE__{type: "syslog"} = source) do
    syslog_changeset(source, %{
      name: source.name,
      source: source.source,
      port: source.port,
      transport: source.transport,
      allowed_hosts: source.allowed_hosts,
      admission_mode: source.admission_mode,
      tls_framing: source.tls_framing,
      tls_client_identities: source.tls_client_identities
    })
  end

  defp normalize_allowed_hosts(changeset) do
    hosts = get_field(changeset, :allowed_hosts) || []

    cond do
      not is_list(hosts) ->
        add_error(changeset, :allowed_hosts, "must be a list")

      length(hosts) > 256 ->
        add_error(changeset, :allowed_hosts, "must contain at most 256 entries")

      true ->
        case Enum.reduce_while(hosts, {:ok, []}, fn host, {:ok, normalized} ->
               case normalize_network(host) do
                 {:ok, value} -> {:cont, {:ok, [value | normalized]}}
                 :error -> {:halt, :error}
               end
             end) do
          {:ok, normalized} ->
            put_change(changeset, :allowed_hosts, normalized |> Enum.reverse() |> Enum.uniq())

          :error ->
            add_error(changeset, :allowed_hosts, "contains an invalid IP address or CIDR")
        end
    end
  end

  defp normalize_network(value) when is_binary(value) do
    case String.split(String.trim(value), "/", parts: 2) do
      [address] -> normalize_address(address, nil)
      [address, prefix] -> normalize_address(address, prefix)
    end
  end

  defp normalize_network(_value), do: :error

  defp normalize_address(address, prefix) do
    with {:ok, parsed} <- :inet.parse_address(String.to_charlist(address)),
         {:ok, normalized_prefix} <- normalize_prefix(parsed, prefix) do
      normalized = parsed |> :inet.ntoa() |> List.to_string()
      {:ok, if(normalized_prefix, do: "#{normalized}/#{normalized_prefix}", else: normalized)}
    else
      _error -> :error
    end
  end

  defp normalize_prefix(_address, nil), do: {:ok, nil}

  defp normalize_prefix(address, prefix) do
    max = if tuple_size(address) == 4, do: 32, else: 128

    case Integer.parse(prefix) do
      {integer, ""} when integer >= 0 and integer <= max -> {:ok, integer}
      _other -> :error
    end
  end

  defp validate_tls(changeset) do
    identities = get_field(changeset, :tls_client_identities) || []

    changeset =
      cond do
        not is_list(identities) ->
          add_error(changeset, :tls_client_identities, "must be a list")

        length(identities) > 16 ->
          add_error(changeset, :tls_client_identities, "must contain at most 16 entries")

        Enum.uniq(identities) != identities ->
          add_error(changeset, :tls_client_identities, "must not contain duplicates")

        Enum.any?(identities, &(not valid_tls_identity?(&1))) ->
          add_error(
            changeset,
            :tls_client_identities,
            "contains an invalid typed SHA-256 fingerprint"
          )

        true ->
          changeset
      end

    if get_field(changeset, :transport) == "tls" do
      changeset
      |> validate_required([:tls_framing])
      |> validate_inclusion(:tls_framing, @tls_framings)
      |> require_tls_identity(identities)
    else
      changeset
      |> put_change(:tls_framing, nil)
      |> put_change(:tls_client_identities, [])
    end
  end

  defp require_tls_identity(changeset, []),
    do: add_error(changeset, :tls_client_identities, "must contain at least one identity")

  defp require_tls_identity(changeset, _identities), do: changeset

  defp valid_tls_identity?(identity) when is_binary(identity) do
    Regex.match?(~r/^(cert|spki)-sha256:[0-9a-f]{64}$/, identity)
  end

  defp valid_tls_identity?(_identity), do: false
end
