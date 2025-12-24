defmodule WhisperLogs.Exports.ExportDestination do
  @moduledoc """
  Schema for export destinations (local folder or S3-compatible storage).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @destination_types ~w(local s3)

  schema "export_destinations" do
    field :name, :string
    field :destination_type, :string
    field :enabled, :boolean, default: true

    # Local destination settings
    field :local_path, :string

    # S3 destination settings
    field :s3_endpoint, :string
    field :s3_bucket, :string
    field :s3_region, :string
    field :s3_access_key_id, :string
    field :s3_secret_access_key, :string
    field :s3_prefix, :string

    # Auto-export settings
    field :auto_export_enabled, :boolean, default: false
    field :auto_export_age_days, :integer

    belongs_to :user, WhisperLogs.Accounts.User

    has_many :export_jobs, WhisperLogs.Exports.ExportJob

    timestamps(type: :utc_datetime)
  end

  def changeset(destination, attrs) do
    destination
    |> cast(attrs, [
      :name,
      :destination_type,
      :enabled,
      :local_path,
      :s3_endpoint,
      :s3_bucket,
      :s3_region,
      :s3_access_key_id,
      :s3_secret_access_key,
      :s3_prefix,
      :auto_export_enabled,
      :auto_export_age_days
    ])
    |> validate_required([:name, :destination_type])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_inclusion(:destination_type, @destination_types)
    |> validate_destination_settings()
    |> validate_auto_export_settings()
  end

  defp validate_destination_settings(changeset) do
    case get_field(changeset, :destination_type) do
      "local" ->
        changeset
        |> validate_required([:local_path])
        |> validate_local_path()

      "s3" ->
        changeset
        |> validate_required([
          :s3_endpoint,
          :s3_bucket,
          :s3_region,
          :s3_access_key_id,
          :s3_secret_access_key
        ])

      _ ->
        changeset
    end
  end

  defp validate_local_path(changeset) do
    case get_change(changeset, :local_path) do
      nil ->
        changeset

      path ->
        # Basic validation to prevent directory traversal
        if String.contains?(path, "..") do
          add_error(changeset, :local_path, "cannot contain '..'")
        else
          changeset
        end
    end
  end

  defp validate_auto_export_settings(changeset) do
    if get_field(changeset, :auto_export_enabled) do
      changeset
      |> validate_required([:auto_export_age_days])
      |> validate_number(:auto_export_age_days, greater_than: 0, less_than_or_equal_to: 365)
    else
      changeset
    end
  end

  def destination_types, do: @destination_types
end
