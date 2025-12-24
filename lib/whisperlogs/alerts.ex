defmodule WhisperLogs.Alerts do
  @moduledoc """
  The Alerts context for managing log alerts and notifications.
  """
  import Ecto.Query, warn: false

  alias WhisperLogs.Repo
  alias WhisperLogs.Alerts.{Alert, NotificationChannel, AlertHistory}
  alias WhisperLogs.Accounts.User
  alias WhisperLogs.Logs

  # ===== Alerts =====

  @doc """
  Lists all alerts for a user.
  """
  def list_alerts(%User{id: user_id}) do
    Alert
    |> where([a], a.user_id == ^user_id)
    |> order_by([a], desc: a.inserted_at)
    |> preload(:notification_channels)
    |> Repo.all()
  end

  @doc """
  Lists all enabled alerts across all users.
  Used by the evaluator.
  """
  def list_enabled_alerts do
    Alert
    |> where([a], a.enabled == true)
    |> preload(:notification_channels)
    |> Repo.all()
  end

  @doc """
  Gets a single alert for a user.
  """
  def get_alert(%User{id: user_id}, alert_id) do
    Alert
    |> where([a], a.user_id == ^user_id and a.id == ^alert_id)
    |> preload(:notification_channels)
    |> Repo.one()
  end

  @doc """
  Gets a single alert by ID (for evaluator).
  """
  def get_alert!(id) do
    Alert
    |> preload(:notification_channels)
    |> Repo.get!(id)
  end

  @doc """
  Creates an alert for a user.
  """
  def create_alert(%User{} = user, attrs, channel_ids \\ []) do
    # Set baseline to current max log ID to prevent retroactive triggering
    max_log_id = Logs.max_log_id()

    Repo.transaction(fn ->
      with {:ok, alert} <-
             %Alert{user_id: user.id, last_seen_log_id: max_log_id}
             |> Alert.changeset(attrs)
             |> Repo.insert(),
           :ok <- attach_channels(alert, channel_ids) do
        Repo.preload(alert, :notification_channels)
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Updates an alert.
  """
  def update_alert(%Alert{} = alert, attrs, channel_ids \\ nil) do
    Repo.transaction(fn ->
      with {:ok, alert} <-
             alert
             |> Alert.changeset(attrs)
             |> Repo.update(),
           :ok <- maybe_update_channels(alert, channel_ids) do
        Repo.preload(alert, :notification_channels, force: true)
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Deletes an alert.
  """
  def delete_alert(%Alert{} = alert) do
    Repo.delete(alert)
  end

  @doc """
  Toggles an alert's enabled status.
  """
  def toggle_alert(%Alert{enabled: false} = alert) do
    # Re-enabling: reset baseline to prevent retroactive triggering
    max_log_id = Logs.max_log_id()

    alert
    |> Ecto.Changeset.change(enabled: true, last_seen_log_id: max_log_id)
    |> Repo.update()
  end

  def toggle_alert(%Alert{enabled: true} = alert) do
    alert
    |> Ecto.Changeset.change(enabled: false)
    |> Repo.update()
  end

  @doc """
  Updates alert state (used by evaluator).
  """
  def update_alert_state(%Alert{} = alert, attrs) do
    alert
    |> Alert.state_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns an Alert changeset for form validation.
  """
  def change_alert(%Alert{} = alert, attrs \\ %{}) do
    Alert.changeset(alert, attrs)
  end

  # ===== Notification Channels =====

  @doc """
  Lists all notification channels for a user.
  """
  def list_notification_channels(%User{id: user_id}) do
    NotificationChannel
    |> where([c], c.user_id == ^user_id)
    |> order_by([c], desc: c.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single notification channel for a user.
  """
  def get_notification_channel(%User{id: user_id}, channel_id) do
    Repo.get_by(NotificationChannel, id: channel_id, user_id: user_id)
  end

  @doc """
  Creates a notification channel for a user.
  """
  def create_notification_channel(%User{} = user, attrs) do
    %NotificationChannel{user_id: user.id}
    |> NotificationChannel.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a notification channel.
  """
  def update_notification_channel(%NotificationChannel{} = channel, attrs) do
    channel
    |> NotificationChannel.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a notification channel.
  """
  def delete_notification_channel(%NotificationChannel{} = channel) do
    Repo.delete(channel)
  end

  @doc """
  Returns a NotificationChannel changeset for form validation.
  """
  def change_notification_channel(%NotificationChannel{} = channel, attrs \\ %{}) do
    NotificationChannel.changeset(channel, attrs)
  end

  # ===== Alert History =====

  @doc """
  Lists alert history for an alert.
  """
  def list_alert_history(%Alert{id: alert_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    AlertHistory
    |> where([h], h.alert_id == ^alert_id)
    |> order_by([h], desc: h.triggered_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Creates an alert history entry.
  """
  def create_alert_history(%Alert{} = alert, trigger_type, trigger_data, notifications) do
    %AlertHistory{
      alert_id: alert.id,
      trigger_type: trigger_type,
      trigger_data: trigger_data,
      notifications_sent: notifications,
      triggered_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
    |> Repo.insert()
  end

  @doc """
  Deletes alert history entries older than the given cutoff datetime.
  Used by retention cleanup.
  """
  def delete_history_before(%DateTime{} = cutoff) do
    AlertHistory
    |> where([h], h.triggered_at < ^cutoff)
    |> Repo.delete_all()
  end

  # ===== Helper Functions =====

  defp attach_channels(%Alert{id: alert_id}, channel_ids) when is_list(channel_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      channel_ids
      |> Enum.reject(&(&1 == "" or is_nil(&1)))
      |> Enum.map(fn channel_id ->
        %{
          alert_id: alert_id,
          notification_channel_id: to_integer(channel_id),
          inserted_at: now,
          updated_at: now
        }
      end)

    if entries != [] do
      Repo.insert_all("alert_notification_channels", entries)
    end

    :ok
  end

  defp to_integer(val) when is_integer(val), do: val
  defp to_integer(val) when is_binary(val), do: String.to_integer(val)

  defp maybe_update_channels(_alert, nil), do: :ok

  defp maybe_update_channels(%Alert{id: alert_id}, channel_ids) do
    from(anc in "alert_notification_channels", where: anc.alert_id == ^alert_id)
    |> Repo.delete_all()

    attach_channels(%Alert{id: alert_id}, channel_ids)
  end
end
