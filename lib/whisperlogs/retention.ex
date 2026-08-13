defmodule WhisperLogs.Retention do
  @moduledoc """
  GenServer that periodically cleans up old data.

  Runs cleanup daily:
  - Logs older than retention period (default 30 days, configurable via WHISPERLOGS_RETENTION_DAYS)
  - Export jobs older than 90 days
  - Alert history older than 90 days
  - Expired user tokens (session: 14 days, magic link: 15 min, email change: 7 days)
  - Expired OAuth credentials and grants revoked for more than 90 days
  """
  use GenServer

  require Logger

  alias WhisperLogs.Logs
  alias WhisperLogs.Alerts
  alias WhisperLogs.Exports
  alias WhisperLogs.Accounts
  alias WhisperLogs.DbAdapter
  alias WhisperLogs.OAuth
  alias WhisperLogs.Repo

  @default_retention_days 30
  @history_retention_days 90
  @cleanup_interval :timer.hours(24)
  @vacuum_interval :timer.minutes(30)
  @vacuum_min_pages 64
  @vacuum_max_pages 2_048

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Schedule first cleanup shortly after startup
    Process.send_after(self(), :cleanup, :timer.seconds(60))
    schedule_vacuum()
    {:ok, %{retention_days: retention_days(), vacuum_warning_logged?: false}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    run_cleanup(state.retention_days)
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(:incremental_vacuum, state) do
    state = run_incremental_vacuum(state)
    schedule_vacuum()
    {:noreply, state}
  end

  defp run_cleanup(retention_days) do
    # Clean up old logs
    retention_cutoff = DateTime.utc_now() |> DateTime.add(-retention_days, :day)
    protected = Exports.earliest_protected_scheduled_time()

    log_cutoff =
      if protected && DateTime.compare(protected, retention_cutoff) == :lt,
        do: protected,
        else: retention_cutoff

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

    case OAuth.delete_expired_credentials() do
      {0, _} -> :ok
      {count, _} -> Logger.info("Retention cleanup: deleted #{count} expired OAuth records")
    end
  rescue
    error ->
      Logger.error("Retention cleanup failed: #{inspect(error)}")
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp schedule_vacuum do
    if DbAdapter.sqlite?() do
      Process.send_after(self(), :incremental_vacuum, @vacuum_interval)
    end
  end

  defp run_incremental_vacuum(state) do
    if DbAdapter.sqlite?(), do: run_sqlite_incremental_vacuum(state), else: state
  end

  defp run_sqlite_incremental_vacuum(state) do
    [[mode]] = Repo.query!("PRAGMA auto_vacuum").rows

    if mode == 2 do
      [[freelist_before]] = Repo.query!("PRAGMA freelist_count").rows

      if freelist_before > 0 do
        target = vacuum_page_target(freelist_before)
        started_at = System.monotonic_time()
        Repo.query!("PRAGMA incremental_vacuum(#{target})", [], timeout: 5_000)
        [[freelist_after]] = Repo.query!("PRAGMA freelist_count").rows

        Logger.info(
          "SQLite incremental vacuum reclaimed #{freelist_before - freelist_after} pages " <>
            "(#{freelist_before} -> #{freelist_after}) in #{elapsed_ms(started_at)}ms"
        )
      end

      %{state | vacuum_warning_logged?: false}
    else
      if !state.vacuum_warning_logged? do
        Logger.warning(
          "SQLite incremental vacuum is inactive; activate it during maintenance with " <>
            "PRAGMA auto_vacuum=INCREMENTAL followed by VACUUM"
        )
      end

      %{state | vacuum_warning_logged?: true}
    end
  rescue
    error ->
      Logger.warning("SQLite incremental vacuum skipped: #{Exception.message(error)}")
      state
  end

  @doc false
  def vacuum_page_target(freelist_count) when is_integer(freelist_count) and freelist_count > 0 do
    target = ceil(freelist_count / 20)
    freelist_count |> min(max(target, @vacuum_min_pages)) |> min(@vacuum_max_pages)
  end

  def vacuum_page_target(0), do: 0

  defp elapsed_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
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
