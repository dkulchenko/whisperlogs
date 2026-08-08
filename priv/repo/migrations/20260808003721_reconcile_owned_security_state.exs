defmodule WhisperLogs.Repo.Migrations.ReconcileOwnedSecurityState do
  use Ecto.Migration

  def up do
    legacy? =
      repo().__adapter__() == Ecto.Adapters.SQLite3 and
        scalar("SELECT COUNT(*) FROM users") == 1 and
        scalar("SELECT COUNT(*) FROM users WHERE email = 'local@localhost' AND is_admin = TRUE") ==
          1

    Enum.each(~w(notification_channels alerts export_destinations export_jobs), fn table ->
      nulls = scalar("SELECT COUNT(*) FROM #{table} WHERE user_id IS NULL")

      cond do
        nulls == 0 ->
          :ok

        legacy? ->
          execute(
            "UPDATE #{table} SET user_id = (SELECT id FROM users WHERE email = 'local@localhost') WHERE user_id IS NULL"
          )

        true ->
          raise "#{table} contains #{nulls} null owners outside the recognized legacy SQLite layout"
      end
    end)

    assert_zero!(
      "SELECT COUNT(*) FROM alert_notification_channels anc LEFT JOIN alerts a ON a.id = anc.alert_id LEFT JOIN notification_channels c ON c.id = anc.notification_channel_id WHERE a.id IS NULL OR c.id IS NULL",
      "dangling alert-notification-channel joins"
    )

    assert_zero!(
      "SELECT COUNT(*) FROM export_jobs j LEFT JOIN export_destinations d ON d.id = j.export_destination_id WHERE d.id IS NULL",
      "dangling export-job destinations"
    )

    execute("""
    DELETE FROM alert_notification_channels
    WHERE id IN (
      SELECT anc.id
      FROM alert_notification_channels anc
      JOIN alerts a ON a.id = anc.alert_id
      JOIN notification_channels c ON c.id = anc.notification_channel_id
      WHERE a.user_id <> c.user_id
    )
    """)

    assert_zero!(
      "SELECT COUNT(*) FROM sources s LEFT JOIN users u ON u.id = s.user_id WHERE u.id IS NULL",
      "dangling source owners"
    )

    assert_zero!(
      "SELECT COUNT(*) FROM alerts a LEFT JOIN users u ON u.id = a.user_id WHERE u.id IS NULL",
      "dangling alert owners"
    )

    assert_zero!(
      "SELECT COUNT(*) FROM notification_channels c LEFT JOIN users u ON u.id = c.user_id WHERE u.id IS NULL",
      "dangling notification-channel owners"
    )

    assert_zero!(
      "SELECT COUNT(*) FROM export_destinations d LEFT JOIN users u ON u.id = d.user_id WHERE u.id IS NULL",
      "dangling export-destination owners"
    )

    assert_zero!(
      "SELECT COUNT(*) FROM export_jobs j LEFT JOIN users u ON u.id = j.user_id WHERE u.id IS NULL",
      "dangling export-job owners"
    )

    assert_zero!(
      "SELECT COUNT(*) FROM export_jobs j JOIN export_destinations d ON d.id = j.export_destination_id WHERE j.user_id <> d.user_id",
      "cross-owner export jobs"
    )

    assert_zero!(
      "SELECT COUNT(*) FROM alerts GROUP BY user_id HAVING COUNT(*) > 100",
      "stored alert quota excess"
    )

    assert_zero!(
      "SELECT COUNT(*) FROM alerts WHERE enabled = TRUE GROUP BY user_id HAVING COUNT(*) > 20",
      "per-user enabled alert quota excess"
    )

    if scalar("SELECT COUNT(*) FROM alerts WHERE enabled = TRUE") > 500,
      do: raise("global enabled alert quota excess")

    assert_zero!(
      "SELECT COUNT(*) FROM sources WHERE type = 'syslog' AND enabled = TRUE AND revoked_at IS NULL GROUP BY user_id HAVING COUNT(*) > 20",
      "per-user syslog quota excess"
    )

    if scalar(
         "SELECT COUNT(*) FROM sources WHERE type = 'syslog' AND enabled = TRUE AND revoked_at IS NULL"
       ) > 500,
       do: raise("global syslog quota excess")

    assert_zero!(
      "SELECT COUNT(*) FROM sources WHERE type = 'syslog' AND enabled = TRUE AND (transport NOT IN ('udp', 'tcp', 'both', 'tls') OR port IS NULL)",
      "invalid enabled syslog source"
    )

    pending = scalar("SELECT COUNT(*) FROM export_jobs WHERE status IN ('pending', 'running')")

    limits =
      Application.get_env(:whisperlogs, :export_limits, %{
        max_pending_per_user: 2,
        max_pending_global: 10
      })

    assert_zero!(
      "SELECT COUNT(*) FROM export_jobs WHERE status IN ('pending', 'running') GROUP BY user_id HAVING COUNT(*) > #{limits.max_pending_per_user}",
      "per-user pending export quota excess"
    )

    if pending > limits.max_pending_global, do: raise("global pending export quota excess")

    allowed_hosts = Application.get_env(:whisperlogs, :s3_allowed_hosts, [])

    endpoints =
      repo().query!(
        "SELECT DISTINCT s3_endpoint FROM export_destinations WHERE destination_type = 's3' AND s3_endpoint IS NOT NULL",
        []
      ).rows
      |> List.flatten()

    unknown = endpoints -- allowed_hosts
    if unknown != [], do: raise("S3 endpoints are not allowlisted: #{inspect(unknown)}")
  end

  def down, do: raise("forward-only ownership reconciliation")

  defp scalar(sql) do
    case repo().query!(sql, []).rows do
      [[value] | _] -> value
      [] -> 0
    end
  end

  defp assert_zero!(sql, message) do
    if scalar(sql) != 0, do: raise(message)
  end
end
