defmodule WhisperLogs.Alerts.Alert do
  @moduledoc """
  Schema for log alerts.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias WhisperLogs.DbAdapter
  alias WhisperLogs.Logs

  @alert_types ~w(any_match velocity)
  @velocity_windows [60, 300, 900, 3600]

  schema "alerts" do
    field :name, :string
    field :description, :string
    field :enabled, :boolean, default: true
    field :search_query, :string
    field :alert_type, :string
    field :velocity_threshold, :integer
    field :velocity_window_seconds, :integer
    field :cooldown_seconds, :integer, default: 300
    field :last_seen_log_id, :integer
    field :last_seen_inserted_at, :utc_datetime_usec
    field :last_triggered_at, :utc_datetime
    field :last_checked_at, :utc_datetime

    belongs_to :user, WhisperLogs.Accounts.User

    many_to_many :notification_channels, WhisperLogs.Alerts.NotificationChannel,
      join_through: "alert_notification_channels"

    has_many :history, WhisperLogs.Alerts.AlertHistory

    timestamps(type: :utc_datetime)
  end

  def changeset(alert, attrs) do
    alert
    |> cast(attrs, [
      :name,
      :description,
      :enabled,
      :search_query,
      :alert_type,
      :velocity_threshold,
      :velocity_window_seconds,
      :cooldown_seconds
    ])
    |> validate_required([:name, :search_query, :alert_type, :cooldown_seconds])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_postgres_text_lengths()
    |> validate_inclusion(:alert_type, @alert_types)
    |> validate_search_query()
    |> validate_velocity_settings()
    |> validate_number(:cooldown_seconds,
      greater_than_or_equal_to: 60,
      less_than_or_equal_to: 86400
    )
  end

  def state_changeset(alert, attrs) do
    alert
    |> cast(attrs, [
      :last_seen_log_id,
      :last_seen_inserted_at,
      :last_triggered_at,
      :last_checked_at
    ])
  end

  # These columns are varchar(255) on PostgreSQL and unbounded on SQLite.
  defp validate_postgres_text_lengths(changeset) do
    if DbAdapter.postgres?() do
      changeset
      |> validate_length(:description, max: 255)
      |> validate_length(:search_query, max: 255)
    else
      changeset
    end
  end

  defp validate_search_query(changeset) do
    case get_change(changeset, :search_query) do
      nil ->
        changeset

      query ->
        if DbAdapter.postgres?() and String.contains?(query, <<0>>) do
          add_error(changeset, :search_query, "cannot contain NUL characters")
        else
          case Logs.validate_search_query(query) do
            :ok ->
              changeset

            {:error, :query_too_complex} ->
              add_error(changeset, :search_query, "has too many terms")

            {:error, :invalid_query} ->
              add_error(changeset, :search_query, "contains a regex this database cannot run")
          end
        end
    end
  end

  defp validate_velocity_settings(changeset) do
    if get_field(changeset, :alert_type) == "velocity" do
      changeset
      |> validate_required([:velocity_threshold, :velocity_window_seconds])
      |> validate_number(:velocity_threshold, greater_than: 0)
      |> validate_inclusion(:velocity_window_seconds, @velocity_windows)
    else
      changeset
    end
  end

  def velocity_windows, do: @velocity_windows
  def alert_types, do: @alert_types
end
