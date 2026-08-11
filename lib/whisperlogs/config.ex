defmodule WhisperLogs.Config do
  @moduledoc """
  Validated operational limits and security-sensitive runtime configuration.

  Values are parsed once by `config/runtime.exs` and validated before any listener,
  scheduler, evaluator, or endpoint starts.
  """

  @app :whisperlogs

  def validate! do
    validate_receiver!()
    validate_exports!()
    validate_alerts!()
    validate_mcp!()
    validate_syslog!()
    validate_s3_hosts!()
    reject_dns_cluster!()
    :ok
  end

  def receiver_limits, do: Application.fetch_env!(@app, :receiver_limits)
  def export_limits, do: Application.fetch_env!(@app, :export_limits)
  def alert_limits, do: Application.fetch_env!(@app, :alert_limits)
  def mcp_limits, do: Application.fetch_env!(@app, :mcp_limits)
  def syslog_limits, do: Application.fetch_env!(@app, :syslog_limits)
  def s3_allowed_hosts, do: Application.fetch_env!(@app, :s3_allowed_hosts)
  def export_root, do: Application.fetch_env!(@app, :export_root)

  defp validate_receiver! do
    limits = receiver_limits()

    positive!(limits, [
      :max_request_bytes,
      :max_batch_size,
      :max_message_bytes,
      :max_metadata_bytes,
      :max_metadata_depth,
      :max_event_bytes
    ])

    require!(
      limits.max_message_bytes <= limits.max_event_bytes,
      "message limit exceeds event limit"
    )

    require!(
      limits.max_metadata_bytes <= limits.max_event_bytes,
      "metadata limit exceeds event limit"
    )

    require!(
      limits.max_event_bytes <= limits.max_request_bytes,
      "event limit exceeds request limit"
    )
  end

  defp validate_exports! do
    limits = export_limits()

    positive!(limits, [
      :max_range_days,
      :max_pending_per_user,
      :max_pending_global,
      :max_rows,
      :max_compressed_bytes,
      :timeout_seconds
    ])

    require!(
      limits.max_pending_per_user <= limits.max_pending_global,
      "per-user pending export limit exceeds global limit"
    )

    root = export_root()

    require!(
      is_binary(root) and Path.type(root) == :absolute,
      "export root must be an absolute path"
    )
  end

  defp validate_alerts! do
    limits = alert_limits()
    positive!(limits, [:max_concurrency, :query_timeout_ms, :cycle_timeout_ms])

    require!(
      limits.cycle_timeout_ms >= limits.query_timeout_ms + 1_000,
      "alert cycle timeout must allow the query timeout plus 1000ms cleanup"
    )

    pool_size = selected_repo().config()[:pool_size] || 10

    require!(
      limits.max_concurrency <= pool_size,
      "alert concurrency exceeds the selected database pool"
    )
  end

  defp validate_mcp! do
    limits = mcp_limits()
    positive!(limits, [:query_timeout_ms, :max_response_bytes, :max_query_bytes])

    require!(
      limits.max_response_bytes >= 65_536,
      "MCP response limit must be at least 65536 bytes"
    )

    require!(
      limits.max_response_bytes >= receiver_limits().max_event_bytes * 2 + 16_384,
      "MCP response limit must fit one complete log plus structured-content compatibility copy"
    )
  end

  defp validate_syslog! do
    limits = syslog_limits()

    positive!(limits, [
      :max_connections,
      :max_connections_per_source,
      :max_frame_bytes,
      :max_queued_per_source,
      :max_queued_global,
      :ingest_workers,
      :idle_timeout_ms,
      :tls_handshake_timeout_ms
    ])

    require!(
      limits.max_connections_per_source <= limits.max_connections,
      "per-source syslog connection limit exceeds global limit"
    )

    require!(
      limits.max_queued_per_source <= limits.max_queued_global,
      "per-source syslog queue limit exceeds global limit"
    )
  end

  defp validate_s3_hosts! do
    Enum.each(s3_allowed_hosts(), fn host ->
      require!(valid_hostname?(host), "invalid S3 allowlist hostname: #{inspect(host)}")
    end)
  end

  defp reject_dns_cluster! do
    case Application.get_env(@app, :dns_cluster_query) do
      value when value in [nil, ""] -> :ok
      _value -> raise ArgumentError, "DNS_CLUSTER_QUERY is unsupported; run one node per database"
    end
  end

  defp selected_repo do
    if WhisperLogs.DbAdapter.sqlite?(),
      do: WhisperLogs.Repo.SQLite,
      else: WhisperLogs.Repo.Postgres
  end

  defp positive!(map, keys) do
    Enum.each(keys, fn key ->
      require!(
        is_integer(Map.fetch!(map, key)) and Map.fetch!(map, key) > 0,
        "#{key} must be positive"
      )
    end)
  end

  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(ArgumentError, message)

  defp valid_hostname?(host) when is_binary(host) do
    byte_size(host) <= 253 and
      host == String.downcase(host) and
      not String.ends_with?(host, ".") and
      match?(%URI{scheme: nil, userinfo: nil, host: nil, port: nil, path: ^host}, URI.parse(host)) and
      Enum.all?(String.split(host, "."), &valid_label?/1) and
      not ip_literal?(host)
  end

  defp valid_hostname?(_host), do: false

  defp valid_label?(label) do
    byte_size(label) in 1..63 and
      Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, label)
  end

  defp ip_literal?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _address} -> true
      {:error, :einval} -> false
    end
  end
end
