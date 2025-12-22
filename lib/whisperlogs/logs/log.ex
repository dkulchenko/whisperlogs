defmodule WhisperLogs.Logs.Log do
  @moduledoc """
  Schema for log entries.
  """
  use Ecto.Schema

  schema "logs" do
    field :timestamp, :utc_datetime_usec
    field :level, :string
    field :message, :string
    field :metadata, :map, default: %{}
    field :request_id, :string
    field :source, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
