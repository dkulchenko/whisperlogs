defmodule WhisperLogs.Exports.Scheduler do
  @moduledoc """
  GenServer that runs scheduled exports before retention cleanup.

  Runs daily, checking for destinations with auto_export_enabled and
  creating export jobs for logs older than auto_export_age_days.
  """
  use GenServer

  require Logger

  alias WhisperLogs.Exports
  alias WhisperLogs.Exports.Exporter

  @check_interval :timer.hours(24)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Schedule first run 30s after startup (before retention's 60s)
    Process.send_after(self(), :run_scheduled_exports, :timer.seconds(30))
    {:ok, %{}}
  end

  @impl true
  def handle_info(:run_scheduled_exports, state) do
    run_all_scheduled_exports()
    schedule_next_run()
    {:noreply, state}
  end

  defp run_all_scheduled_exports do
    destinations = Exports.list_auto_export_destinations()

    if destinations != [] do
      Logger.info("Running scheduled exports for #{length(destinations)} destination(s)")
    end

    Enum.each(destinations, fn dest ->
      try do
        run_scheduled_export(dest)
      rescue
        error ->
          Logger.error(
            "Scheduled export failed for destination #{dest.id}: #{Exception.message(error)}"
          )
      end
    end)
  end

  defp run_scheduled_export(destination) do
    # Calculate time range: logs older than auto_export_age_days
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-destination.auto_export_age_days, :day)
      |> DateTime.truncate(:second)

    # Get the timestamp of last successful export to avoid re-exporting
    last_export_end = Exports.get_last_successful_export_end(destination)

    # Default start: epoch or oldest possible date
    from_timestamp = last_export_end || ~U[2020-01-01 00:00:00Z]
    to_timestamp = cutoff

    # Only create job if there's a valid range (at least 1 hour of data)
    if DateTime.compare(from_timestamp, to_timestamp) == :lt and
         DateTime.diff(to_timestamp, from_timestamp, :hour) >= 1 do
      Logger.info(
        "Creating scheduled export for destination #{destination.id}: " <>
          "#{DateTime.to_iso8601(from_timestamp)} to #{DateTime.to_iso8601(to_timestamp)}"
      )

      {:ok, job} =
        Exports.create_export_job(destination, nil, %{
          trigger: "scheduled",
          from_timestamp: from_timestamp,
          to_timestamp: to_timestamp
        })

      # Run export synchronously in scheduler context
      # Could be made async if needed for parallel exports
      Exporter.run_export(job)
    else
      Logger.debug(
        "No logs to export for destination #{destination.id}: " <>
          "range #{inspect(from_timestamp)} to #{inspect(to_timestamp)} is not valid"
      )
    end
  end

  defp schedule_next_run do
    Process.send_after(self(), :run_scheduled_exports, @check_interval)
  end
end
