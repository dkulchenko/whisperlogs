defmodule WhisperLogs.Alerts.Evaluator do
  @moduledoc """
  GenServer that periodically evaluates all enabled alerts.

  Runs every 30 seconds, checking each alert against matching logs
  and triggering notifications when conditions are met.
  """
  use GenServer

  require Logger

  alias WhisperLogs.Alerts
  alias WhisperLogs.Alerts.Alert
  alias WhisperLogs.Alerts.Notifier
  alias WhisperLogs.Logs
  alias WhisperLogs.Logs.Log
  alias WhisperLogs.Logs.SearchParser
  alias WhisperLogs.Repo

  import Ecto.Query, warn: false

  @evaluation_interval :timer.seconds(30)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_evaluation()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:evaluate, state) do
    evaluate_all_alerts()
    schedule_evaluation()
    {:noreply, state}
  end

  defp schedule_evaluation do
    Process.send_after(self(), :evaluate, @evaluation_interval)
  end

  defp evaluate_all_alerts do
    alerts = Alerts.list_enabled_alerts()

    Enum.each(alerts, fn alert ->
      try do
        evaluate_alert(alert)
      rescue
        error ->
          Logger.error("Alert evaluation failed for #{alert.id}: #{Exception.message(error)}")
      end
    end)
  end

  defp evaluate_alert(%Alert{alert_type: "any_match"} = alert) do
    if in_cooldown?(alert) do
      :skip
    else
      evaluate_any_match(alert)
    end
  end

  defp evaluate_alert(%Alert{alert_type: "velocity"} = alert) do
    if in_cooldown?(alert) do
      :skip
    else
      evaluate_velocity(alert)
    end
  end

  defp in_cooldown?(%Alert{last_triggered_at: nil}), do: false

  defp in_cooldown?(%Alert{last_triggered_at: last, cooldown_seconds: cooldown}) do
    DateTime.diff(DateTime.utc_now(), last, :second) < cooldown
  end

  # ===== Any Match Evaluation =====

  defp evaluate_any_match(%Alert{search_query: query, last_seen_log_id: last_id} = alert) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case find_new_matching_log(query, last_id) do
      nil ->
        Alerts.update_alert_state(alert, %{last_checked_at: now})

      log ->
        trigger_data = %{
          "log_id" => log.id,
          "log_message" => String.slice(log.message, 0, 200),
          "log_level" => log.level,
          "log_source" => log.source,
          "log_timestamp" => DateTime.to_iso8601(log.timestamp)
        }

        notifications = Notifier.send_alert(alert, "any_match", trigger_data)

        case Alerts.create_alert_history(alert, "any_match", trigger_data, notifications) do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.error("Failed to create alert history: #{inspect(changeset.errors)}")
        end

        case Alerts.update_alert_state(alert, %{
               last_seen_log_id: log.id,
               last_triggered_at: now,
               last_checked_at: now
             }) do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.error("Failed to update alert state: #{inspect(changeset.errors)}")
        end
    end
  end

  defp find_new_matching_log(search_query, last_id) do
    case SearchParser.parse(search_query) do
      {:ok, []} ->
        nil

      {:ok, tokens} ->
        base_query =
          Log
          |> order_by([l], asc: l.id)
          |> limit(1)

        query_with_filter =
          if last_id do
            where(base_query, [l], l.id > ^last_id)
          else
            base_query
          end

        query_with_filter
        |> Logs.apply_search_tokens(tokens)
        |> Repo.one()
    end
  end

  # ===== Velocity Evaluation =====

  defp evaluate_velocity(%Alert{} = alert) do
    %{
      search_query: query,
      velocity_threshold: threshold,
      velocity_window_seconds: window
    } = alert

    count = count_matches_in_window(query, window)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if count >= threshold do
      trigger_data = %{
        "count" => count,
        "threshold" => threshold,
        "window_seconds" => window
      }

      notifications = Notifier.send_alert(alert, "velocity", trigger_data)

      case Alerts.create_alert_history(alert, "velocity", trigger_data, notifications) do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          Logger.error("Failed to create alert history: #{inspect(changeset.errors)}")
      end

      case Alerts.update_alert_state(alert, %{
             last_triggered_at: now,
             last_checked_at: now
           }) do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          Logger.error("Failed to update alert state: #{inspect(changeset.errors)}")
      end
    else
      Alerts.update_alert_state(alert, %{last_checked_at: now})
    end
  end

  defp count_matches_in_window(search_query, window_seconds) do
    cutoff = DateTime.add(DateTime.utc_now(), -window_seconds, :second)

    case SearchParser.parse(search_query) do
      {:ok, []} ->
        0

      {:ok, tokens} ->
        Log
        |> where([l], l.timestamp >= ^cutoff)
        |> Logs.apply_search_tokens(tokens)
        |> Repo.aggregate(:count, :id)
    end
  end
end
