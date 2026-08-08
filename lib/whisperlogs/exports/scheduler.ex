defmodule WhisperLogs.Exports.Scheduler do
  @moduledoc "The single sequential owner of pending and scheduled exports."
  use GenServer
  require Logger

  alias WhisperLogs.Exports
  alias WhisperLogs.Exports.{Exporter, Workspace}

  @check_interval :timer.hours(24)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    timeout = WhisperLogs.Config.export_limits().timeout_seconds
    Workspace.cleanup_abandoned(timeout)
    Exports.fail_interrupted_jobs()
    send(self(), :scheduled_tick)
    send(self(), :drain)
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:drain, state) do
    send(self(), :drain)
    {:noreply, state}
  end

  @impl true
  def handle_info(:scheduled_tick, state) do
    admit_next_scheduled_ranges()
    send(self(), :drain)
    Process.send_after(self(), :scheduled_tick, @check_interval)
    {:noreply, state}
  end

  def handle_info(:drain, state) do
    case Exports.next_pending_job() do
      nil ->
        {:noreply, state}

      job ->
        result = Exporter.run_export(job)

        # A failed scheduled range retries only on a later startup/daily tick.
        # Other destinations can use the newly freed capacity immediately.
        skip_destination_id =
          case result do
            {:ok, %{status: "failed", trigger: "scheduled"} = failed} ->
              failed.export_destination_id

            _other ->
              nil
          end

        admit_next_scheduled_ranges(skip_destination_id)

        send(self(), :drain)
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp admit_next_scheduled_ranges(skip_destination_id \\ nil) do
    Exports.list_auto_export_destinations()
    |> Enum.reject(&(&1.id == skip_destination_id))
    |> Enum.each(fn destination ->
      cutoff =
        DateTime.utc_now()
        |> DateTime.add(-destination.auto_export_age_days, :day)
        |> DateTime.truncate(:second)

      from =
        Exports.get_last_successful_scheduled_export_end(destination) ||
          Exports.oldest_observed_time()

      if from && DateTime.compare(from, cutoff) == :lt do
        to = min_datetime(DateTime.add(from, 1, :day), cutoff)

        case Exports.admit_scheduled_job(destination, from, to) do
          {:ok, _job} ->
            :ok

          {:error, reason}
          when reason in [
                 :user_pending_quota_exceeded,
                 :global_pending_quota_exceeded,
                 :duplicate_active_export
               ] ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Could not admit scheduled export for destination #{destination.id}: #{inspect(reason)}"
            )
        end
      end
    end)
  end

  defp min_datetime(left, right),
    do: if(DateTime.compare(left, right) == :gt, do: right, else: left)
end
