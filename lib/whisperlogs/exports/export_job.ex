defmodule WhisperLogs.Exports.ExportJob do
  @moduledoc """
  Schema for tracking export job executions and their status.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending running completed failed)
  @triggers ~w(manual scheduled)

  schema "export_jobs" do
    field :status, :string, default: "pending"
    field :trigger, :string
    field :from_timestamp, :utc_datetime_usec
    field :to_timestamp, :utc_datetime_usec
    field :file_name, :string
    field :file_size_bytes, :integer
    field :log_count, :integer
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :error_message, :string

    belongs_to :export_destination, WhisperLogs.Exports.ExportDestination
    belongs_to :user, WhisperLogs.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :trigger,
      :from_timestamp,
      :to_timestamp
    ])
    |> validate_required([:trigger, :from_timestamp, :to_timestamp])
    |> validate_inclusion(:trigger, @triggers)
    |> validate_date_range()
  end

  def status_changeset(job, attrs) do
    job
    |> cast(attrs, [
      :status,
      :file_name,
      :file_size_bytes,
      :log_count,
      :started_at,
      :completed_at,
      :error_message
    ])
    |> validate_inclusion(:status, @statuses)
  end

  defp validate_date_range(changeset) do
    from = get_field(changeset, :from_timestamp)
    to = get_field(changeset, :to_timestamp)

    cond do
      is_nil(from) or is_nil(to) ->
        changeset

      DateTime.compare(from, to) != :lt ->
        add_error(changeset, :to_timestamp, "must be after from_timestamp")

      true ->
        changeset
    end
  end

  def statuses, do: @statuses
  def triggers, do: @triggers
end
