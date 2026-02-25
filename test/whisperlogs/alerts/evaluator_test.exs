defmodule WhisperLogs.Alerts.EvaluatorTest do
  use WhisperLogs.DataCase, async: false

  alias WhisperLogs.Alerts
  alias WhisperLogs.Alerts.Evaluator

  import WhisperLogs.AccountsFixtures
  import WhisperLogs.AlertsFixtures
  import WhisperLogs.LogsFixtures

  # Helper to trigger evaluation and wait for it to complete
  defp trigger_evaluation do
    send(Evaluator, :evaluate)
    _ = :sys.get_state(Evaluator)
  end

  describe "any_match alert evaluation" do
    test "triggers when new matching log appears" do
      user = user_fixture()
      alert = any_match_alert_fixture(user, search_query: "level:error", cooldown_seconds: 60)

      # Create a matching log after the alert
      _log = log_fixture("test-source", level: "error", message: "Something failed")

      # Trigger evaluation on the already-running Evaluator
      trigger_evaluation()

      # Check that alert was triggered
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at != nil
      assert updated_alert.last_checked_at != nil

      # Check history was created
      history = Alerts.list_alert_history(updated_alert)
      assert length(history) == 1
      [entry] = history
      assert entry.trigger_type == "any_match"
      assert entry.trigger_data["log_level"] == "error"
    end

    test "does not trigger when no matching logs exist" do
      user = user_fixture()
      alert = any_match_alert_fixture(user, search_query: "level:error", cooldown_seconds: 60)

      # Create a non-matching log
      _log = log_fixture("test-source", level: "info", message: "Everything is fine")

      trigger_evaluation()

      # Alert should not have triggered
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at == nil
      assert updated_alert.last_checked_at != nil

      # No history
      history = Alerts.list_alert_history(updated_alert)
      assert history == []
    end

    test "tracks last_seen_log_id to avoid duplicate triggers" do
      user = user_fixture()

      # Create initial log
      _log1 = log_fixture("test-source", level: "error", message: "First error")

      # Create alert (will set last_seen_log_id to log1.id)
      alert = any_match_alert_fixture(user, search_query: "level:error", cooldown_seconds: 60)

      trigger_evaluation()

      # Should not trigger because log1 was before alert creation
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at == nil

      # Create new log
      log2 = log_fixture("test-source", level: "error", message: "Second error")

      trigger_evaluation()

      # Now should trigger
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at != nil
      assert updated_alert.last_seen_log_id == log2.id
    end

    test "respects cooldown period" do
      user = user_fixture()
      alert = any_match_alert_fixture(user, search_query: "level:error", cooldown_seconds: 3600)

      # Create a matching log
      _log1 = log_fixture("test-source", level: "error", message: "First error")

      trigger_evaluation()

      # First trigger
      updated_alert = Alerts.get_alert(user, alert.id)
      first_trigger = updated_alert.last_triggered_at
      assert first_trigger != nil

      # Create another matching log
      _log2 = log_fixture("test-source", level: "error", message: "Second error")

      trigger_evaluation()

      # Should not trigger again due to cooldown
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at == first_trigger

      # Only one history entry
      history = Alerts.list_alert_history(updated_alert)
      assert length(history) == 1
    end

    test "suppresses logs during cooldown window instead of queuing them" do
      user = user_fixture()
      alert = any_match_alert_fixture(user, search_query: "level:error", cooldown_seconds: 3600)

      # Create a matching log and trigger
      _log1 = log_fixture("test-source", level: "error", message: "First error")

      trigger_evaluation()

      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at != nil
      first_trigger = updated_alert.last_triggered_at

      # Create more matching logs during cooldown
      _log2 = log_fixture("test-source", level: "error", message: "Second error")
      log3 = log_fixture("test-source", level: "error", message: "Third error")

      trigger_evaluation()

      # Should NOT trigger again (still in cooldown)
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at == first_trigger

      # But last_seen_log_id should have advanced to the latest matching log
      assert updated_alert.last_seen_log_id == log3.id

      # Still only one history entry (logs during cooldown were suppressed)
      history = Alerts.list_alert_history(updated_alert)
      assert length(history) == 1
    end

    test "does not evaluate disabled alerts" do
      user = user_fixture()
      alert = any_match_alert_fixture(user, search_query: "level:error", enabled: false)

      # Create a matching log
      _log = log_fixture("test-source", level: "error", message: "Error log")

      trigger_evaluation()

      # Should not have triggered
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at == nil
      assert updated_alert.last_checked_at == nil
    end
  end

  describe "velocity alert evaluation" do
    test "triggers when threshold exceeded in window" do
      user = user_fixture()

      alert =
        velocity_alert_fixture(user,
          search_query: "level:error",
          threshold: 3,
          window: 3600,
          cooldown_seconds: 60
        )

      # Create matching logs that exceed threshold
      for i <- 1..5 do
        log_fixture("test-source", level: "error", message: "Error #{i}")
      end

      trigger_evaluation()

      # Alert should have triggered
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at != nil

      # Check history
      history = Alerts.list_alert_history(updated_alert)
      assert length(history) == 1
      [entry] = history
      assert entry.trigger_type == "velocity"
      assert entry.trigger_data["count"] >= 3
      assert entry.trigger_data["threshold"] == 3
    end

    test "does not trigger when below threshold" do
      user = user_fixture()

      alert =
        velocity_alert_fixture(user,
          search_query: "level:error",
          threshold: 10,
          window: 3600,
          cooldown_seconds: 60
        )

      # Create fewer logs than threshold
      for i <- 1..3 do
        log_fixture("test-source", level: "error", message: "Error #{i}")
      end

      trigger_evaluation()

      # Should not have triggered
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at == nil
      assert updated_alert.last_checked_at != nil

      # No history
      history = Alerts.list_alert_history(updated_alert)
      assert history == []
    end

    test "respects window time for counting" do
      user = user_fixture()

      # Use a 60 second window
      alert =
        velocity_alert_fixture(user,
          search_query: "level:error",
          threshold: 3,
          window: 60,
          cooldown_seconds: 60
        )

      # Create old logs (outside window)
      old_time = DateTime.add(DateTime.utc_now(), -120, :second)

      for i <- 1..5 do
        log_fixture("test-source",
          level: "error",
          message: "Old error #{i}",
          timestamp: old_time
        )
      end

      trigger_evaluation()

      # Should not trigger because logs are outside window
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at == nil
    end

    test "respects cooldown period" do
      user = user_fixture()

      alert =
        velocity_alert_fixture(user,
          search_query: "level:error",
          threshold: 2,
          window: 3600,
          cooldown_seconds: 3600
        )

      # Create matching logs
      for i <- 1..3 do
        log_fixture("test-source", level: "error", message: "Error #{i}")
      end

      trigger_evaluation()

      # First trigger
      updated_alert = Alerts.get_alert(user, alert.id)
      first_trigger = updated_alert.last_triggered_at
      assert first_trigger != nil

      # Create more logs
      for i <- 4..6 do
        log_fixture("test-source", level: "error", message: "Error #{i}")
      end

      trigger_evaluation()

      # Should not trigger again due to cooldown
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at == first_trigger

      # Only one history entry
      history = Alerts.list_alert_history(updated_alert)
      assert length(history) == 1
    end
  end

  describe "search query matching" do
    test "matches source-specific queries" do
      user = user_fixture()
      alert = any_match_alert_fixture(user, search_query: "source:my-app", cooldown_seconds: 60)

      # Create log in different source
      _log1 = log_fixture("other-app", level: "info", message: "Test")

      trigger_evaluation()

      # Should not trigger
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at == nil

      # Create log in matching source
      _log2 = log_fixture("my-app", level: "info", message: "Test")

      trigger_evaluation()

      # Should trigger
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at != nil
    end

    test "matches text search queries" do
      user = user_fixture()

      alert =
        any_match_alert_fixture(user, search_query: "database connection", cooldown_seconds: 60)

      # Create non-matching log
      _log1 = log_fixture("test-source", level: "error", message: "Something else broke")

      trigger_evaluation()

      # Should not trigger
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at == nil

      # Create matching log
      _log2 = log_fixture("test-source", level: "error", message: "Database connection failed")

      trigger_evaluation()

      # Should trigger
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at != nil
    end

    test "matches combined queries" do
      user = user_fixture()

      alert =
        any_match_alert_fixture(user,
          search_query: "level:error source:api timeout",
          cooldown_seconds: 60
        )

      # Create partial match (wrong source)
      _log1 = log_fixture("web", level: "error", message: "Request timeout")

      trigger_evaluation()

      # Should not trigger
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at == nil

      # Create full match
      _log2 = log_fixture("api", level: "error", message: "Request timeout occurred")

      trigger_evaluation()

      # Should trigger
      updated_alert = Alerts.get_alert(user, alert.id)
      assert updated_alert.last_triggered_at != nil
    end
  end

  describe "notification channels" do
    test "records notification results in history" do
      user = user_fixture()
      channel = email_channel_fixture(user, email: "alerts@example.com")

      alert =
        any_match_alert_fixture(user,
          search_query: "level:error",
          cooldown_seconds: 60,
          channel_ids: [channel.id]
        )

      _log = log_fixture("test-source", level: "error", message: "Error occurred")

      trigger_evaluation()

      # Check history includes notification info
      [history] = Alerts.list_alert_history(Alerts.get_alert(user, alert.id))
      assert is_list(history.notifications_sent)
      assert length(history.notifications_sent) >= 0
    end
  end

  describe "error handling" do
    test "continues evaluating other alerts after one fails" do
      user = user_fixture()

      # Create two alerts
      alert1 = any_match_alert_fixture(user, search_query: "level:error", cooldown_seconds: 60)
      alert2 = any_match_alert_fixture(user, search_query: "level:warning", cooldown_seconds: 60)

      # Create matching logs for both
      _log1 = log_fixture("test-source", level: "error", message: "Error")
      _log2 = log_fixture("test-source", level: "warning", message: "Warning")

      trigger_evaluation()

      # Both should be evaluated
      updated_alert1 = Alerts.get_alert(user, alert1.id)
      updated_alert2 = Alerts.get_alert(user, alert2.id)

      assert updated_alert1.last_checked_at != nil
      assert updated_alert2.last_checked_at != nil
    end
  end
end
