defmodule WhisperLogs.Alerts.AlertHistory do
  @moduledoc """
  Schema for alert trigger history.
  """
  use Ecto.Schema

  schema "alert_history" do
    field :trigger_type, :string
    field :trigger_data, :map, default: %{}
    field :notifications_sent, {:array, :map}, default: []
    field :triggered_at, :utc_datetime

    belongs_to :alert, WhisperLogs.Alerts.Alert

    timestamps(type: :utc_datetime)
  end
end
