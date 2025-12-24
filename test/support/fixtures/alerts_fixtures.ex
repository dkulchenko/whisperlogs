defmodule WhisperLogs.AlertsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `WhisperLogs.Alerts` context.
  """

  alias WhisperLogs.Alerts
  import WhisperLogs.AccountsFixtures

  @doc """
  Creates an email notification channel.

  ## Examples

      email_channel_fixture(user)
      email_channel_fixture(user, email: "alerts@example.com")
  """
  def email_channel_fixture(user \\ nil, attrs \\ []) do
    user = user || user_fixture()
    email = Keyword.get(attrs, :email, "test#{System.unique_integer()}@example.com")
    name = Keyword.get(attrs, :name, "Test Email Channel")
    enabled = Keyword.get(attrs, :enabled, true)

    {:ok, channel} =
      Alerts.create_notification_channel(user, %{
        name: name,
        channel_type: "email",
        enabled: enabled,
        config: %{"email" => email}
      })

    channel
  end

  @doc """
  Creates a Pushover notification channel.

  ## Examples

      pushover_channel_fixture(user)
      pushover_channel_fixture(user, user_key: "abc123", app_token: "xyz789")
  """
  def pushover_channel_fixture(user \\ nil, attrs \\ []) do
    user = user || user_fixture()
    user_key = Keyword.get(attrs, :user_key, "test_user_key_#{System.unique_integer()}")
    app_token = Keyword.get(attrs, :app_token, "test_app_token_#{System.unique_integer()}")
    name = Keyword.get(attrs, :name, "Test Pushover Channel")
    enabled = Keyword.get(attrs, :enabled, true)

    {:ok, channel} =
      Alerts.create_notification_channel(user, %{
        name: name,
        channel_type: "pushover",
        enabled: enabled,
        config: %{
          "user_key" => user_key,
          "app_token" => app_token,
          "priority" => Keyword.get(attrs, :priority, 0)
        }
      })

    channel
  end

  @doc """
  Creates a notification channel of any type.

  ## Examples

      notification_channel_fixture(user, channel_type: "email")
      notification_channel_fixture(user, channel_type: "pushover")
  """
  def notification_channel_fixture(user \\ nil, attrs \\ []) do
    case Keyword.get(attrs, :channel_type, "email") do
      "email" -> email_channel_fixture(user, attrs)
      "pushover" -> pushover_channel_fixture(user, attrs)
    end
  end

  @doc """
  Creates an "any_match" alert.

  ## Examples

      any_match_alert_fixture(user)
      any_match_alert_fixture(user, search_query: "level:error")
      any_match_alert_fixture(user, search_query: "error", channel_ids: [channel.id])
  """
  def any_match_alert_fixture(user \\ nil, attrs \\ []) do
    user = user || user_fixture()
    name = Keyword.get(attrs, :name, "Test Alert #{System.unique_integer()}")
    search_query = Keyword.get(attrs, :search_query, "level:error")
    cooldown = Keyword.get(attrs, :cooldown_seconds, 300)
    channel_ids = Keyword.get(attrs, :channel_ids, [])

    {:ok, alert} =
      Alerts.create_alert(
        user,
        %{
          name: name,
          search_query: search_query,
          alert_type: "any_match",
          cooldown_seconds: cooldown,
          description: Keyword.get(attrs, :description),
          enabled: Keyword.get(attrs, :enabled, true)
        },
        channel_ids
      )

    alert
  end

  @doc """
  Creates a "velocity" alert.

  ## Examples

      velocity_alert_fixture(user)
      velocity_alert_fixture(user, threshold: 100, window: 300)
  """
  def velocity_alert_fixture(user \\ nil, attrs \\ []) do
    user = user || user_fixture()
    name = Keyword.get(attrs, :name, "Test Velocity Alert #{System.unique_integer()}")
    search_query = Keyword.get(attrs, :search_query, "level:error")
    threshold = Keyword.get(attrs, :threshold, 10)
    window = Keyword.get(attrs, :window, 300)
    cooldown = Keyword.get(attrs, :cooldown_seconds, 300)
    channel_ids = Keyword.get(attrs, :channel_ids, [])

    {:ok, alert} =
      Alerts.create_alert(
        user,
        %{
          name: name,
          search_query: search_query,
          alert_type: "velocity",
          velocity_threshold: threshold,
          velocity_window_seconds: window,
          cooldown_seconds: cooldown,
          description: Keyword.get(attrs, :description),
          enabled: Keyword.get(attrs, :enabled, true)
        },
        channel_ids
      )

    alert
  end

  @doc """
  Creates an alert of the specified type.

  ## Examples

      alert_fixture(user, alert_type: "any_match")
      alert_fixture(user, alert_type: "velocity", threshold: 50)
  """
  def alert_fixture(user \\ nil, attrs \\ []) do
    case Keyword.get(attrs, :alert_type, "any_match") do
      "any_match" -> any_match_alert_fixture(user, attrs)
      "velocity" -> velocity_alert_fixture(user, attrs)
    end
  end

  @doc """
  Creates an alert history entry for testing.
  """
  def alert_history_fixture(alert, attrs \\ []) do
    trigger_type = Keyword.get(attrs, :trigger_type, "any_match")
    trigger_data = Keyword.get(attrs, :trigger_data, %{"log_id" => 1, "message" => "Test"})

    notifications =
      Keyword.get(attrs, :notifications, [
        %{"type" => "email", "address" => "test@example.com", "status" => "sent"}
      ])

    {:ok, history} = Alerts.create_alert_history(alert, trigger_type, trigger_data, notifications)
    history
  end
end
