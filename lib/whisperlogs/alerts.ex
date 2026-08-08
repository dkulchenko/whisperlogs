defmodule WhisperLogs.Alerts do
  @moduledoc """
  The Alerts context for managing log alerts and notifications.
  """
  import Ecto.Query, warn: false

  alias WhisperLogs.Repo
  alias WhisperLogs.Alerts.{Alert, NotificationChannel, AlertHistory}
  alias WhisperLogs.Accounts.{Scope, User}
  alias WhisperLogs.Logs

  # ===== Alerts =====

  @doc """
  Lists all alerts for a user.
  """
  def list_alerts(%Scope{user: %User{id: user_id}}) do
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
    alerts =
      Alert
      |> where([a], a.enabled == true)
      |> order_by([a], asc_nulls_first: a.last_checked_at, asc: a.id)
      |> limit(500)
      |> preload(:notification_channels)
      |> Repo.all()

    grouped = Enum.group_by(alerts, & &1.user_id)

    alerts
    |> Enum.map(& &1.user_id)
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(grouped, &1))
    |> round_robin()
  end

  @doc """
  Gets a single alert for a user.
  """
  def get_alert(%Scope{user: %User{id: user_id}}, alert_id) do
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
  def create_alert(%Scope{user: %User{} = user}, attrs, channel_ids \\ []) do
    {last_seen_inserted_at, last_seen_log_id} = Logs.max_observed_cursor()

    WhisperLogs.DbAdapter.serialized_transaction(:alerts, fn ->
      enabled? = Map.get(attrs, "enabled", Map.get(attrs, :enabled, true)) not in [false, "false"]
      enforce_alert_quota!(user.id, enabled?, nil)
      channels = resolve_owned_channels!(user.id, channel_ids)

      alert =
        %Alert{
          user_id: user.id,
          last_seen_log_id: last_seen_log_id,
          last_seen_inserted_at: last_seen_inserted_at
        }
        |> Alert.changeset(attrs)
        |> Repo.insert()
        |> unwrap!()

      attach_channels(alert, channels)
      Repo.preload(alert, :notification_channels)
    end)
  end

  @doc """
  Updates an alert.
  """
  def update_alert(%Scope{user: %User{id: user_id}} = scope, alert_id, attrs, channel_ids \\ nil) do
    WhisperLogs.DbAdapter.serialized_transaction(:alerts, fn ->
      alert = get_alert(scope, alert_id) || Repo.rollback(:not_found)
      changeset = Alert.changeset(alert, attrs)
      enabled? = Ecto.Changeset.get_field(changeset, :enabled)
      enforce_alert_quota!(user_id, enabled?, alert.id)

      channels =
        if is_nil(channel_ids), do: nil, else: resolve_owned_channels!(user_id, channel_ids)

      updated = changeset |> Repo.update() |> unwrap!()
      maybe_update_channels(updated, channels)
      Repo.preload(updated, :notification_channels, force: true)
    end)
  end

  @doc """
  Deletes an alert.
  """
  def delete_alert(%Scope{} = scope, alert_id) do
    case get_alert(scope, alert_id) do
      nil -> {:error, :not_found}
      alert -> Repo.delete(alert)
    end
  end

  @doc """
  Toggles an alert's enabled status.
  """
  def toggle_alert(%Scope{user: %User{id: user_id}} = scope, alert_id) do
    WhisperLogs.DbAdapter.serialized_transaction(:alerts, fn ->
      alert = get_alert(scope, alert_id) || Repo.rollback(:not_found)

      if alert.enabled do
        alert |> Ecto.Changeset.change(enabled: false) |> Repo.update() |> unwrap!()
      else
        enforce_alert_quota!(user_id, true, alert.id)
        {last_seen_inserted_at, last_seen_log_id} = Logs.max_observed_cursor()

        alert
        |> Ecto.Changeset.change(
          enabled: true,
          last_seen_inserted_at: last_seen_inserted_at,
          last_seen_log_id: last_seen_log_id
        )
        |> Repo.update()
        |> unwrap!()
      end
    end)
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
  def list_notification_channels(%Scope{user: %User{id: user_id}}) do
    NotificationChannel
    |> where([c], c.user_id == ^user_id)
    |> order_by([c], desc: c.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single notification channel for a user.
  """
  def get_notification_channel(%Scope{user: %User{id: user_id}}, channel_id) do
    Repo.get_by(NotificationChannel, id: channel_id, user_id: user_id)
  end

  @doc """
  Creates a notification channel for a user.
  """
  def create_notification_channel(%Scope{user: %User{} = user}, attrs) do
    %NotificationChannel{user_id: user.id}
    |> NotificationChannel.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a notification channel.
  """
  def update_notification_channel(%Scope{} = scope, channel_id, attrs) do
    case get_notification_channel(scope, channel_id) do
      nil -> {:error, :not_found}
      channel -> channel |> NotificationChannel.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Deletes a notification channel.
  """
  def delete_notification_channel(%Scope{} = scope, channel_id) do
    case get_notification_channel(scope, channel_id) do
      nil -> {:error, :not_found}
      channel -> Repo.delete(channel)
    end
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
  def list_alert_history(%Scope{} = scope, alert_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    if get_alert(scope, alert_id) do
      AlertHistory
      |> where([h], h.alert_id == ^alert_id)
      |> order_by([h], desc: h.triggered_at, desc: h.id)
      |> limit(^limit)
      |> Repo.all()
    else
      []
    end
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

  def notification_channels_for_delivery(%Alert{id: alert_id, user_id: user_id}) do
    NotificationChannel
    |> join(:inner, [c], anc in "alert_notification_channels",
      on: anc.notification_channel_id == c.id
    )
    |> where([c, anc], anc.alert_id == ^alert_id and c.user_id == ^user_id and c.enabled)
    |> Repo.all()
  end

  defp attach_channels(%Alert{id: alert_id}, channels) when is_list(channels) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      Enum.map(channels, fn channel ->
        %{
          alert_id: alert_id,
          notification_channel_id: channel.id,
          inserted_at: now,
          updated_at: now
        }
      end)

    if entries != [] do
      Repo.insert_all("alert_notification_channels", entries)
    end

    :ok
  end

  defp maybe_update_channels(_alert, nil), do: :ok

  defp maybe_update_channels(%Alert{id: alert_id} = alert, channels) do
    from(anc in "alert_notification_channels", where: anc.alert_id == ^alert_id)
    |> Repo.delete_all()

    attach_channels(alert, channels)
  end

  defp resolve_owned_channels!(user_id, channel_ids) do
    ids =
      channel_ids
      |> Enum.reject(&(&1 in ["", nil]))
      |> Enum.map(&parse_id!/1)
      |> Enum.uniq()

    channels =
      NotificationChannel
      |> where([c], c.user_id == ^user_id and c.id in ^ids)
      |> Repo.all()

    if length(channels) == length(ids), do: channels, else: Repo.rollback(:invalid_channels)
  end

  defp parse_id!(id) when is_integer(id), do: id

  defp parse_id!(id) when is_binary(id) do
    case Integer.parse(id) do
      {integer, ""} -> integer
      _other -> Repo.rollback(:invalid_channels)
    end
  end

  defp enforce_alert_quota!(user_id, enabled?, exclude_id) do
    stored_query = from a in Alert, where: a.user_id == ^user_id
    enabled_user_query = from a in stored_query, where: a.enabled
    enabled_global_query = from a in Alert, where: a.enabled

    stored_query =
      if exclude_id, do: where(stored_query, [a], a.id != ^exclude_id), else: stored_query

    enabled_user_query =
      if exclude_id,
        do: where(enabled_user_query, [a], a.id != ^exclude_id),
        else: enabled_user_query

    enabled_global_query =
      if exclude_id,
        do: where(enabled_global_query, [a], a.id != ^exclude_id),
        else: enabled_global_query

    cond do
      Repo.aggregate(stored_query, :count) >= 100 ->
        Repo.rollback(:alert_stored_quota_exceeded)

      enabled? and Repo.aggregate(enabled_user_query, :count) >= 20 ->
        Repo.rollback(:alert_user_enabled_quota_exceeded)

      enabled? and Repo.aggregate(enabled_global_query, :count) >= 500 ->
        Repo.rollback(:alert_global_enabled_quota_exceeded)

      true ->
        :ok
    end
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)

  defp round_robin(groups), do: round_robin(groups, [])
  defp round_robin([], acc), do: acc

  defp round_robin(groups, acc) do
    {heads, tails} =
      groups
      |> Enum.reduce({[], []}, fn
        [head | tail], {heads, tails} ->
          {[head | heads], if(tail == [], do: tails, else: [tail | tails])}

        [], result ->
          result
      end)

    round_robin(Enum.reverse(tails), acc ++ Enum.reverse(heads))
  end
end
