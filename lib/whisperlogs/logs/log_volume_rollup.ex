defmodule WhisperLogs.Logs.LogVolumeRollup do
  @moduledoc """
  Persisted UTC log volume totals used by the metrics page.
  """

  use Ecto.Schema

  @primary_key false
  schema "log_volume_rollups" do
    field :granularity, :string
    field :bucket_start, :utc_datetime_usec
    field :log_count, :integer
    field :byte_count, :integer
  end
end
