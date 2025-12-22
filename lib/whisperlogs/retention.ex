defmodule WhisperLogs.Retention do
  @moduledoc """
  GenServer that periodically cleans up old logs based on retention policy.

  Runs cleanup daily, deleting logs older than the configured retention period.
  Default retention is 30 days, configurable via WHISPERLOGS_RETENTION_DAYS env var.
  """
  use GenServer

  require Logger

  alias WhisperLogs.Logs

  @default_retention_days 30
  @cleanup_interval :timer.hours(24)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Schedule first cleanup shortly after startup
    Process.send_after(self(), :cleanup, :timer.seconds(60))
    {:ok, %{retention_days: retention_days()}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    run_cleanup(state.retention_days)
    schedule_cleanup()
    {:noreply, state}
  end

  defp run_cleanup(retention_days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days, :day)

    case Logs.delete_before(cutoff) do
      {0, _} ->
        Logger.debug("Retention cleanup: no logs to delete")

      {count, _} ->
        Logger.info("Retention cleanup: deleted #{count} logs older than #{retention_days} days")
    end
  rescue
    error ->
      Logger.error("Retention cleanup failed: #{inspect(error)}")
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp retention_days do
    case System.get_env("WHISPERLOGS_RETENTION_DAYS") do
      nil -> @default_retention_days
      days -> String.to_integer(days)
    end
  end
end
