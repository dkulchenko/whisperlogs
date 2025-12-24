defmodule WhisperLogs.Retention do
  @moduledoc """
  GenServer that periodically cleans up old data.

  Runs cleanup daily:
  - Logs older than retention period (default 30 days, configurable via WHISPERLOGS_RETENTION_DAYS)
  - Export jobs older than 90 days
  - Alert history older than 90 days
  - Expired user tokens (session: 14 days, magic link: 15 min, email change: 7 days)
  """
  use GenServer

  require Logger

  alias WhisperLogs.Logs
  alias WhisperLogs.Alerts
  alias WhisperLogs.Exports
  alias WhisperLogs.Accounts

  @default_retention_days 30
  @history_retention_days 90
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
    # Clean up old logs
    log_cutoff = DateTime.utc_now() |> DateTime.add(-retention_days, :day)

    case Logs.delete_before(log_cutoff) do
      {0, _} ->
        Logger.debug("Retention cleanup: no logs to delete")

      {count, _} ->
        Logger.info("Retention cleanup: deleted #{count} logs older than #{retention_days} days")
    end

    # Clean up old export jobs and alert history
    history_cutoff = DateTime.utc_now() |> DateTime.add(-@history_retention_days, :day)

    case Exports.delete_jobs_before(history_cutoff) do
      {0, _} -> :ok
      {count, _} -> Logger.info("Retention cleanup: deleted #{count} old export jobs")
    end

    case Alerts.delete_history_before(history_cutoff) do
      {0, _} -> :ok
      {count, _} -> Logger.info("Retention cleanup: deleted #{count} old alert history entries")
    end

    # Clean up expired user tokens
    case Accounts.delete_expired_tokens() do
      {0, _} -> :ok
      {count, _} -> Logger.info("Retention cleanup: deleted #{count} expired user tokens")
    end
  rescue
    error ->
      Logger.error("Retention cleanup failed: #{inspect(error)}")
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  @doc """
  Returns the configured retention period in days.
  Configurable via WHISPERLOGS_RETENTION_DAYS environment variable.
  Defaults to 30 days.
  """
  def retention_days do
    case System.get_env("WHISPERLOGS_RETENTION_DAYS") do
      nil -> @default_retention_days
      days -> String.to_integer(days)
    end
  end
end
