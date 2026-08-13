defmodule WhisperLogs.Alerts.Evaluator do
  @moduledoc "Evaluates enabled alerts with bounded, owner-fair concurrency."
  use GenServer

  require Logger
  import Ecto.Query, warn: false

  alias WhisperLogs.Alerts
  alias WhisperLogs.Alerts.{Alert, Notifier}
  alias WhisperLogs.Logs
  alias WhisperLogs.Logs.{Log, SearchParser}
  alias WhisperLogs.Repo

  @evaluation_interval :timer.seconds(30)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

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

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_evaluation, do: Process.send_after(self(), :evaluate, @evaluation_interval)

  defp evaluate_all_alerts do
    limits = WhisperLogs.Config.alert_limits()
    deadline = System.monotonic_time(:millisecond) + limits.cycle_timeout_ms
    task_timeout = limits.query_timeout_ms + 1_000
    launch_deadline = deadline - task_timeout
    alerts = Alerts.list_enabled_alerts()

    alerts
    |> Stream.take_while(fn _alert -> System.monotonic_time(:millisecond) < launch_deadline end)
    |> Task.async_stream(
      &safely_evaluate/1,
      max_concurrency: limits.max_concurrency,
      # The query-level timeout must fire first. In SQLite, Exqlite's
      # DBConnection timeout path calls sqlite3_cancel before the outer task is
      # eligible for termination; PostgreSQL also gets time to cancel/rollback.
      timeout: task_timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(alerts)
    |> Enum.each(fn
      {{:exit, :timeout}, alert} ->
        mark_checked(alert)
        Logger.warning("Alert evaluation timed out for alert #{alert.id}")

      {_result, _alert} ->
        :ok
    end)
  end

  defp safely_evaluate(alert) do
    evaluate_alert(alert)
  rescue
    error ->
      mark_checked(alert)
      Logger.warning("Alert evaluation failed for alert #{alert.id}: #{Exception.message(error)}")
  catch
    :exit, reason ->
      mark_checked(alert)
      Logger.warning("Alert evaluation stopped for alert #{alert.id}: #{inspect(reason)}")
  end

  defp evaluate_alert(%Alert{alert_type: "any_match"} = alert) do
    if in_cooldown?(alert), do: advance_cursor(alert), else: evaluate_any_match(alert)
  end

  defp evaluate_alert(%Alert{alert_type: "velocity"} = alert) do
    if in_cooldown?(alert), do: mark_checked(alert), else: evaluate_velocity(alert)
  end

  defp in_cooldown?(%Alert{last_triggered_at: nil}), do: false

  defp in_cooldown?(%Alert{last_triggered_at: last, cooldown_seconds: cooldown}) do
    DateTime.diff(DateTime.utc_now(), last, :second) < cooldown
  end

  defp evaluate_any_match(alert) do
    now = now()
    cutoff = Logs.max_observed_cursor()

    case matching_log(alert, :first, cutoff) do
      nil ->
        advance_to_cursor(alert, cutoff, now)

      log ->
        trigger_data = %{
          "log_id" => log.id,
          "log_message" => String.slice(log.message, 0, 200),
          "log_level" => log.level,
          "log_source" => log.source,
          "log_timestamp" => DateTime.to_iso8601(log.timestamp)
        }

        notifications = Notifier.send_alert(alert, "any_match", trigger_data)
        _ = Alerts.create_alert_history(alert, "any_match", trigger_data, notifications)

        Alerts.update_alert_state(alert, %{
          last_seen_inserted_at: log.inserted_at,
          last_seen_log_id: log.id,
          last_triggered_at: now,
          last_checked_at: now
        })
    end
  end

  defp advance_cursor(alert) do
    advance_to_cursor(alert, Logs.max_observed_cursor(), now())
  end

  defp matching_log(%Alert{} = alert, direction, cutoff) do
    with {:ok, [_ | _] = tokens} <- SearchParser.parse(alert.search_query) do
      order = if direction == :first, do: :asc, else: :desc

      Log
      |> after_cursor(alert.last_seen_inserted_at, alert.last_seen_log_id)
      |> through_cursor(cutoff)
      |> order_by([l], [{^order, l.inserted_at}, {^order, l.id}])
      |> limit(1)
      |> Logs.apply_search_tokens(tokens)
      |> one_with_timeout()
    else
      _ -> nil
    end
  end

  defp after_cursor(query, nil, _id), do: query

  defp after_cursor(query, inserted_at, id) do
    where(query, ^WhisperLogs.DbAdapter.observed_after(inserted_at, id || 0))
  end

  defp through_cursor(query, {nil, _id}), do: where(query, [l], false)

  defp through_cursor(query, {inserted_at, id}) do
    where(query, ^WhisperLogs.DbAdapter.observed_through(inserted_at, id))
  end

  defp advance_to_cursor(alert, {nil, _id}, checked_at) do
    Alerts.update_alert_state(alert, %{last_checked_at: checked_at})
  end

  defp advance_to_cursor(alert, {inserted_at, id}, checked_at) do
    Alerts.update_alert_state(alert, %{
      last_seen_inserted_at: inserted_at,
      last_seen_log_id: id,
      last_checked_at: checked_at
    })
  end

  defp evaluate_velocity(alert) do
    count = count_matches_in_window(alert.search_query, alert.velocity_window_seconds)
    now = now()

    if count >= alert.velocity_threshold do
      trigger_data = %{
        "count" => count,
        "threshold" => alert.velocity_threshold,
        "window_seconds" => alert.velocity_window_seconds
      }

      notifications = Notifier.send_alert(alert, "velocity", trigger_data)
      _ = Alerts.create_alert_history(alert, "velocity", trigger_data, notifications)
      Alerts.update_alert_state(alert, %{last_triggered_at: now, last_checked_at: now})
    else
      Alerts.update_alert_state(alert, %{last_checked_at: now})
    end
  end

  defp count_matches_in_window(search_query, seconds) do
    cutoff = DateTime.add(DateTime.utc_now(), -seconds, :second)

    with {:ok, [_ | _] = tokens} <- SearchParser.parse(search_query) do
      Log
      |> where([l], l.inserted_at >= ^cutoff)
      |> Logs.apply_search_tokens(tokens)
      |> aggregate_with_timeout()
    else
      _ -> 0
    end
  end

  defp one_with_timeout(query),
    do: with_statement_timeout(fn -> Repo.one(query, timeout: query_timeout()) end)

  defp aggregate_with_timeout(query),
    do:
      with_statement_timeout(fn ->
        Repo.aggregate(query, :count, :id, timeout: query_timeout())
      end)

  defp with_statement_timeout(fun) do
    if WhisperLogs.DbAdapter.postgres?() do
      {:ok, result} =
        Repo.transaction(
          fn ->
            Repo.query!("SELECT set_config('statement_timeout', $1, true)", [
              Integer.to_string(query_timeout())
            ])

            fun.()
          end,
          timeout: query_timeout() + 1_000
        )

      result
    else
      fun.()
    end
  end

  defp query_timeout, do: WhisperLogs.Config.alert_limits().query_timeout_ms
  defp mark_checked(alert), do: Alerts.update_alert_state(alert, %{last_checked_at: now()})
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
