defmodule WhisperLogs.Alerts.Alert do
  @moduledoc """
  Schema for log alerts.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias WhisperLogs.Logs.SearchParser

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
    |> cast(attrs, [:last_seen_log_id, :last_triggered_at, :last_checked_at])
  end

  defp validate_search_query(changeset) do
    case get_change(changeset, :search_query) do
      nil ->
        changeset

      query ->
        # SearchParser.parse always returns {:ok, tokens}
        # We validate that the query produces at least one token
        case SearchParser.parse(query) do
          {:ok, []} ->
            # Empty tokens means the query was whitespace-only
            changeset

          {:ok, _tokens} ->
            changeset
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
