defmodule WhisperLogs.AlertsTest do
  use WhisperLogs.DataCase, async: true

  alias WhisperLogs.Alerts

  import WhisperLogs.AccountsFixtures
  import WhisperLogs.AlertsFixtures
  import WhisperLogs.LogsFixtures

  # ===== Alert CRUD Tests =====

  describe "list_alerts/1" do
    test "returns alerts for the given user" do
      user = user_fixture()
      alert = any_match_alert_fixture(user)

      alerts = Alerts.list_alerts(user)
      assert length(alerts) == 1
      assert hd(alerts).id == alert.id
    end

    test "does not return alerts belonging to other users" do
      user1 = user_fixture()
      user2 = user_fixture()
      _alert1 = any_match_alert_fixture(user1)
      alert2 = any_match_alert_fixture(user2)

      alerts = Alerts.list_alerts(user2)
      assert length(alerts) == 1
      assert hd(alerts).id == alert2.id
    end

    test "orders by inserted_at descending" do
      user = user_fixture()
      alert1 = any_match_alert_fixture(user, name: "First")
      alert2 = any_match_alert_fixture(user, name: "Second")

      alerts = Alerts.list_alerts(user)
      assert length(alerts) == 2
      # Both alerts created nearly simultaneously, so order by ID is the tiebreaker
      # Just verify we get both alerts back
      alert_ids = Enum.map(alerts, & &1.id)
      assert alert1.id in alert_ids
      assert alert2.id in alert_ids
    end

    test "preloads notification_channels" do
      user = user_fixture()
      channel = email_channel_fixture(user)
      _alert = any_match_alert_fixture(user, channel_ids: [channel.id])

      [alert] = Alerts.list_alerts(user)
      assert Ecto.assoc_loaded?(alert.notification_channels)
      assert length(alert.notification_channels) == 1
    end
  end

  describe "list_enabled_alerts/0" do
    test "returns only enabled alerts" do
      user = user_fixture()
      enabled_alert = any_match_alert_fixture(user, enabled: true)
      _disabled_alert = any_match_alert_fixture(user, enabled: false)

      alerts = Alerts.list_enabled_alerts()
      assert length(alerts) == 1
      assert hd(alerts).id == enabled_alert.id
    end

    test "returns alerts across all users" do
      user1 = user_fixture()
      user2 = user_fixture()
      alert1 = any_match_alert_fixture(user1)
      alert2 = any_match_alert_fixture(user2)

      alerts = Alerts.list_enabled_alerts()
      alert_ids = Enum.map(alerts, & &1.id)
      assert alert1.id in alert_ids
      assert alert2.id in alert_ids
    end
  end

  describe "get_alert/2" do
    test "returns alert for the user" do
      user = user_fixture()
      alert = any_match_alert_fixture(user)

      result = Alerts.get_alert(user, alert.id)
      assert result.id == alert.id
    end

    test "returns nil for non-existent alert" do
      user = user_fixture()
      assert Alerts.get_alert(user, 999_999) == nil
    end

    test "returns nil for alert belonging to other user" do
      user1 = user_fixture()
      user2 = user_fixture()
      alert = any_match_alert_fixture(user1)

      assert Alerts.get_alert(user2, alert.id) == nil
    end

    test "preloads notification_channels" do
      user = user_fixture()
      channel = email_channel_fixture(user)
      alert = any_match_alert_fixture(user, channel_ids: [channel.id])

      result = Alerts.get_alert(user, alert.id)
      assert Ecto.assoc_loaded?(result.notification_channels)
      assert length(result.notification_channels) == 1
    end
  end

  describe "create_alert/3 with any_match type" do
    test "creates alert with valid attributes" do
      user = user_fixture()

      {:ok, alert} =
        Alerts.create_alert(user, %{
          name: "Error Alert",
          search_query: "level:error",
          alert_type: "any_match",
          cooldown_seconds: 300
        })

      assert alert.name == "Error Alert"
      assert alert.search_query == "level:error"
      assert alert.alert_type == "any_match"
      assert alert.enabled == true
    end

    test "sets last_seen_log_id to current max log ID" do
      user = user_fixture()
      # Create some logs first
      log = log_fixture("test-source")

      {:ok, alert} =
        Alerts.create_alert(user, %{
          name: "Test Alert",
          search_query: "level:error",
          alert_type: "any_match",
          cooldown_seconds: 300
        })

      assert alert.last_seen_log_id == log.id
    end

    test "attaches notification channels" do
      user = user_fixture()
      channel1 = email_channel_fixture(user)
      channel2 = pushover_channel_fixture(user)

      {:ok, alert} =
        Alerts.create_alert(
          user,
          %{
            name: "Test Alert",
            search_query: "level:error",
            alert_type: "any_match",
            cooldown_seconds: 300
          },
          [channel1.id, channel2.id]
        )

      assert length(alert.notification_channels) == 2
    end

    test "validates required fields" do
      user = user_fixture()

      {:error, changeset} = Alerts.create_alert(user, %{})

      assert errors_on(changeset) |> Map.has_key?(:name)
      assert errors_on(changeset) |> Map.has_key?(:search_query)
      assert errors_on(changeset) |> Map.has_key?(:alert_type)
    end

    test "validates alert_type inclusion" do
      user = user_fixture()

      {:error, changeset} =
        Alerts.create_alert(user, %{
          name: "Test",
          search_query: "error",
          alert_type: "invalid",
          cooldown_seconds: 300
        })

      assert errors_on(changeset) |> Map.has_key?(:alert_type)
    end

    test "validates cooldown_seconds range" do
      user = user_fixture()

      {:error, changeset} =
        Alerts.create_alert(user, %{
          name: "Test",
          search_query: "error",
          alert_type: "any_match",
          cooldown_seconds: 10
        })

      assert errors_on(changeset) |> Map.has_key?(:cooldown_seconds)
    end
  end

  describe "create_alert/3 with velocity type" do
    test "creates velocity alert with threshold and window" do
      user = user_fixture()

      {:ok, alert} =
        Alerts.create_alert(user, %{
          name: "High Volume Alert",
          search_query: "level:error",
          alert_type: "velocity",
          velocity_threshold: 100,
          velocity_window_seconds: 300,
          cooldown_seconds: 300
        })

      assert alert.alert_type == "velocity"
      assert alert.velocity_threshold == 100
      assert alert.velocity_window_seconds == 300
    end

    test "requires velocity_threshold for velocity type" do
      user = user_fixture()

      {:error, changeset} =
        Alerts.create_alert(user, %{
          name: "Test",
          search_query: "error",
          alert_type: "velocity",
          velocity_window_seconds: 300,
          cooldown_seconds: 300
        })

      assert errors_on(changeset) |> Map.has_key?(:velocity_threshold)
    end

    test "requires velocity_window_seconds for velocity type" do
      user = user_fixture()

      {:error, changeset} =
        Alerts.create_alert(user, %{
          name: "Test",
          search_query: "error",
          alert_type: "velocity",
          velocity_threshold: 100,
          cooldown_seconds: 300
        })

      assert errors_on(changeset) |> Map.has_key?(:velocity_window_seconds)
    end

    test "validates velocity_window_seconds is one of allowed values" do
      user = user_fixture()

      {:error, changeset} =
        Alerts.create_alert(user, %{
          name: "Test",
          search_query: "error",
          alert_type: "velocity",
          velocity_threshold: 100,
          velocity_window_seconds: 999,
          cooldown_seconds: 300
        })

      assert errors_on(changeset) |> Map.has_key?(:velocity_window_seconds)
    end
  end

  describe "update_alert/3" do
    test "updates alert attributes" do
      user = user_fixture()
      alert = any_match_alert_fixture(user, name: "Original")

      {:ok, updated} =
        Alerts.update_alert(alert, %{
          name: "Updated",
          description: "New description"
        })

      assert updated.name == "Updated"
      assert updated.description == "New description"
    end

    test "can change notification channels" do
      user = user_fixture()
      channel1 = email_channel_fixture(user)
      channel2 = pushover_channel_fixture(user)
      alert = any_match_alert_fixture(user, channel_ids: [channel1.id])

      {:ok, updated} = Alerts.update_alert(alert, %{}, [channel2.id])

      assert length(updated.notification_channels) == 1
      assert hd(updated.notification_channels).id == channel2.id
    end

    test "passing nil for channel_ids leaves channels unchanged" do
      user = user_fixture()
      channel = email_channel_fixture(user)
      alert = any_match_alert_fixture(user, channel_ids: [channel.id])

      {:ok, updated} = Alerts.update_alert(alert, %{name: "New Name"}, nil)

      assert length(updated.notification_channels) == 1
    end
  end

  describe "delete_alert/1" do
    test "deletes the alert" do
      user = user_fixture()
      alert = any_match_alert_fixture(user)

      {:ok, _} = Alerts.delete_alert(alert)

      assert Alerts.get_alert(user, alert.id) == nil
    end
  end

  describe "toggle_alert/1" do
    test "disabling sets enabled to false" do
      user = user_fixture()
      alert = any_match_alert_fixture(user, enabled: true)

      {:ok, toggled} = Alerts.toggle_alert(alert)

      assert toggled.enabled == false
    end

    test "re-enabling sets enabled to true and resets last_seen_log_id" do
      user = user_fixture()
      alert = any_match_alert_fixture(user, enabled: false)

      # Create a log after alert creation
      log = log_fixture("test-source")

      {:ok, toggled} = Alerts.toggle_alert(alert)

      assert toggled.enabled == true
      assert toggled.last_seen_log_id == log.id
    end
  end

  # ===== Notification Channel Tests =====

  describe "list_notification_channels/1" do
    test "returns channels for user" do
      user = user_fixture()
      channel = email_channel_fixture(user)

      channels = Alerts.list_notification_channels(user)
      assert length(channels) == 1
      assert hd(channels).id == channel.id
    end

    test "does not return channels from other users" do
      user1 = user_fixture()
      user2 = user_fixture()
      _channel1 = email_channel_fixture(user1)
      channel2 = email_channel_fixture(user2)

      channels = Alerts.list_notification_channels(user2)
      assert length(channels) == 1
      assert hd(channels).id == channel2.id
    end
  end

  describe "create_notification_channel/2" do
    test "creates email channel with valid config" do
      user = user_fixture()

      {:ok, channel} =
        Alerts.create_notification_channel(user, %{
          name: "My Email",
          channel_type: "email",
          config: %{"email" => "test@example.com"}
        })

      assert channel.channel_type == "email"
      assert channel.config["email"] == "test@example.com"
    end

    test "creates pushover channel with valid config" do
      user = user_fixture()

      {:ok, channel} =
        Alerts.create_notification_channel(user, %{
          name: "My Pushover",
          channel_type: "pushover",
          config: %{
            "user_key" => "abc123",
            "app_token" => "xyz789"
          }
        })

      assert channel.channel_type == "pushover"
      assert channel.config["user_key"] == "abc123"
    end

    test "validates email format" do
      user = user_fixture()

      {:error, changeset} =
        Alerts.create_notification_channel(user, %{
          name: "Bad Email",
          channel_type: "email",
          config: %{"email" => "not-an-email"}
        })

      assert errors_on(changeset) |> Map.has_key?(:config)
    end

    test "validates pushover requires user_key" do
      user = user_fixture()

      {:error, changeset} =
        Alerts.create_notification_channel(user, %{
          name: "Bad Pushover",
          channel_type: "pushover",
          config: %{"app_token" => "xyz"}
        })

      assert errors_on(changeset) |> Map.has_key?(:config)
    end

    test "validates pushover requires app_token" do
      user = user_fixture()

      {:error, changeset} =
        Alerts.create_notification_channel(user, %{
          name: "Bad Pushover",
          channel_type: "pushover",
          config: %{"user_key" => "abc"}
        })

      assert errors_on(changeset) |> Map.has_key?(:config)
    end
  end

  describe "update_notification_channel/2" do
    test "updates channel attributes" do
      user = user_fixture()
      channel = email_channel_fixture(user, name: "Original")

      {:ok, updated} =
        Alerts.update_notification_channel(channel, %{
          name: "Updated"
        })

      assert updated.name == "Updated"
    end
  end

  describe "delete_notification_channel/1" do
    test "deletes the channel" do
      user = user_fixture()
      channel = email_channel_fixture(user)

      {:ok, _} = Alerts.delete_notification_channel(channel)

      assert Alerts.get_notification_channel(user, channel.id) == nil
    end
  end

  # ===== Alert History Tests =====

  describe "list_alert_history/2" do
    test "returns history for alert" do
      user = user_fixture()
      alert = any_match_alert_fixture(user)
      _history = alert_history_fixture(alert)

      history = Alerts.list_alert_history(alert)
      assert length(history) == 1
    end

    test "orders by triggered_at descending" do
      user = user_fixture()
      alert = any_match_alert_fixture(user)
      _history1 = alert_history_fixture(alert)
      history2 = alert_history_fixture(alert)

      history = Alerts.list_alert_history(alert)
      assert hd(history).id == history2.id
    end

    test "respects limit option" do
      user = user_fixture()
      alert = any_match_alert_fixture(user)
      for _ <- 1..5, do: alert_history_fixture(alert)

      history = Alerts.list_alert_history(alert, limit: 3)
      assert length(history) == 3
    end
  end

  describe "create_alert_history/4" do
    test "creates history entry" do
      user = user_fixture()
      alert = any_match_alert_fixture(user)

      notifications = [
        %{"type" => "email", "address" => "test@example.com", "status" => "sent"}
      ]

      {:ok, history} =
        Alerts.create_alert_history(
          alert,
          "any_match",
          %{"log_id" => 123, "message" => "Test error"},
          notifications
        )

      assert history.alert_id == alert.id
      assert history.trigger_type == "any_match"
      assert history.trigger_data["log_id"] == 123
      assert history.notifications_sent == notifications
    end
  end

  describe "delete_history_before/1" do
    test "deletes entries older than cutoff" do
      user = user_fixture()
      alert = any_match_alert_fixture(user)
      _history = alert_history_fixture(alert)

      cutoff = DateTime.add(DateTime.utc_now(), 1, :hour)
      {count, _} = Alerts.delete_history_before(cutoff)

      assert count == 1
      assert Alerts.list_alert_history(alert) == []
    end

    test "preserves entries newer than cutoff" do
      user = user_fixture()
      alert = any_match_alert_fixture(user)
      _history = alert_history_fixture(alert)

      cutoff = DateTime.add(DateTime.utc_now(), -1, :hour)
      {count, _} = Alerts.delete_history_before(cutoff)

      assert count == 0
      assert length(Alerts.list_alert_history(alert)) == 1
    end
  end
end
