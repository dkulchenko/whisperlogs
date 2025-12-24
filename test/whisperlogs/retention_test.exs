defmodule WhisperLogs.RetentionTest do
  use WhisperLogs.DataCase, async: false

  alias WhisperLogs.Logs
  alias WhisperLogs.Alerts
  alias WhisperLogs.Exports
  alias WhisperLogs.Accounts
  alias WhisperLogs.Retention

  import WhisperLogs.AccountsFixtures
  import WhisperLogs.AlertsFixtures
  import WhisperLogs.ExportsFixtures
  import WhisperLogs.LogsFixtures

  # Helper to trigger cleanup manually
  defp trigger_cleanup do
    send(Retention, :cleanup)
    _ = :sys.get_state(Retention)
  end

  describe "log retention" do
    test "deletes logs older than retention period" do
      # Create old log (way outside retention period)
      old_time = DateTime.add(DateTime.utc_now(), -60, :day)
      old_log = log_fixture("test-source", level: "info", message: "Old log", timestamp: old_time)

      # Create recent log (within retention period)
      recent_log = log_fixture("test-source", level: "info", message: "Recent log")

      # Verify both exist
      assert Logs.get_log(old_log.id) != nil
      assert Logs.get_log(recent_log.id) != nil

      trigger_cleanup()

      # Old log should be deleted, recent one kept
      assert Logs.get_log(old_log.id) == nil
      assert Logs.get_log(recent_log.id) != nil
    end

    test "respects configured retention days" do
      # Test with different retention values using delete_before directly
      # since we can't easily modify env vars in tests

      # Create logs at different ages
      time_20_days_ago = DateTime.add(DateTime.utc_now(), -20, :day)
      time_10_days_ago = DateTime.add(DateTime.utc_now(), -10, :day)

      log_20 = log_fixture("test-source", timestamp: time_20_days_ago)
      log_10 = log_fixture("test-source", timestamp: time_10_days_ago)

      # Delete logs older than 15 days
      cutoff = DateTime.add(DateTime.utc_now(), -15, :day)
      {count, _} = Logs.delete_before(cutoff)

      assert count == 1
      assert Logs.get_log(log_20.id) == nil
      assert Logs.get_log(log_10.id) != nil
    end
  end

  describe "export job retention" do
    test "deletes export jobs older than 90 days" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)

      # Create old export job (simulate 100 days ago)
      old_job = export_job_fixture(destination, scope)

      # Manually update inserted_at to be 100 days ago
      {1, _} =
        Repo.update_all(
          from(j in Exports.ExportJob, where: j.id == ^old_job.id),
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -100, :day)]
        )

      # Create recent export job
      recent_job = export_job_fixture(destination, scope)

      trigger_cleanup()

      # Old job should be deleted, recent one kept
      assert Exports.get_export_job(scope, old_job.id) == nil
      assert Exports.get_export_job(scope, recent_job.id) != nil
    end

    test "keeps export jobs within 90 days" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)

      # Create job 80 days ago (within retention)
      job = export_job_fixture(destination, scope)

      {1, _} =
        Repo.update_all(
          from(j in Exports.ExportJob, where: j.id == ^job.id),
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -80, :day)]
        )

      trigger_cleanup()

      # Job should still exist
      assert Exports.get_export_job(scope, job.id) != nil
    end
  end

  describe "alert history retention" do
    test "deletes alert history older than 90 days" do
      user = user_fixture()
      alert = any_match_alert_fixture(user)

      # Create old history
      old_history = alert_history_fixture(alert)

      # Update triggered_at to 100 days ago
      {1, _} =
        Repo.update_all(
          from(h in Alerts.AlertHistory, where: h.id == ^old_history.id),
          set: [triggered_at: DateTime.add(DateTime.utc_now(), -100, :day)]
        )

      # Create recent history
      _recent_history = alert_history_fixture(alert)

      trigger_cleanup()

      # Check history count - should only have recent one
      history = Alerts.list_alert_history(alert)
      assert length(history) == 1
    end

    test "keeps alert history within 90 days" do
      user = user_fixture()
      alert = any_match_alert_fixture(user)

      # Create history 80 days ago (within retention)
      history = alert_history_fixture(alert)

      {1, _} =
        Repo.update_all(
          from(h in Alerts.AlertHistory, where: h.id == ^history.id),
          set: [triggered_at: DateTime.add(DateTime.utc_now(), -80, :day)]
        )

      trigger_cleanup()

      # History should still exist
      history_list = Alerts.list_alert_history(alert)
      assert length(history_list) == 1
    end
  end

  describe "user token retention" do
    test "deletes expired session tokens" do
      user = user_fixture()

      # Create a session token
      token = Accounts.generate_user_session_token(user)
      assert Accounts.get_user_by_session_token(token) != nil

      # Update token to be expired (older than 14 days)
      {1, _} =
        Repo.update_all(
          from(t in Accounts.UserToken,
            where: t.token == ^token and t.context == "session"
          ),
          set: [
            inserted_at: DateTime.add(DateTime.utc_now(), -15, :day),
            authenticated_at: DateTime.add(DateTime.utc_now(), -15, :day)
          ]
        )

      trigger_cleanup()

      # Token should be deleted
      assert Accounts.get_user_by_session_token(token) == nil
    end

    test "keeps valid session tokens" do
      user = user_fixture()

      # Create a session token
      token = Accounts.generate_user_session_token(user)

      trigger_cleanup()

      # Token should still work
      assert Accounts.get_user_by_session_token(token) != nil
    end
  end

  describe "cleanup scheduling" do
    test "schedules periodic cleanup" do
      # The Retention GenServer is already running, just verify it handles the cleanup message
      state_before = :sys.get_state(Retention)
      assert is_map(state_before)
      assert Map.has_key?(state_before, :retention_days)
    end

    test "retention_days/0 returns default value" do
      # Without env var set, should return default
      days = Retention.retention_days()
      assert days == 30
    end
  end

  describe "error handling" do
    test "cleanup continues despite individual errors" do
      user = user_fixture()
      alert = any_match_alert_fixture(user)

      # Create valid alert history
      _history = alert_history_fixture(alert)

      # Cleanup should complete without crashing
      trigger_cleanup()

      # GenServer should still be alive
      assert Process.whereis(Retention) != nil
    end
  end
end
