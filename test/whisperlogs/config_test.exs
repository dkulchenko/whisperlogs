defmodule WhisperLogs.ConfigTest do
  use ExUnit.Case, async: false

  alias WhisperLogs.Config

  @keys ~w(receiver_limits export_limits alert_limits syslog_limits s3_allowed_hosts export_root dns_cluster_query)a

  setup do
    original = Map.new(@keys, &{&1, Application.get_env(:whisperlogs, &1)})

    on_exit(fn ->
      Enum.each(original, fn {key, value} -> Application.put_env(:whisperlogs, key, value) end)
    end)

    :ok
  end

  test "accepts the shipped operational defaults" do
    assert :ok = Config.validate!()
  end

  test "rejects inconsistent receiver limits" do
    limits = Config.receiver_limits() |> Map.put(:max_event_bytes, 1)
    Application.put_env(:whisperlogs, :receiver_limits, limits)

    assert_raise ArgumentError, ~r/message limit exceeds event limit/, &Config.validate!/0
  end

  test "rejects relative export roots and inverted pending quotas" do
    Application.put_env(:whisperlogs, :export_root, "relative/exports")

    assert_raise ArgumentError, ~r/export root must be an absolute path/, &Config.validate!/0

    Application.put_env(:whisperlogs, :export_root, "/tmp/exports")

    limits =
      Config.export_limits()
      |> Map.put(:max_pending_per_user, 11)
      |> Map.put(:max_pending_global, 10)

    Application.put_env(:whisperlogs, :export_limits, limits)

    assert_raise ArgumentError, ~r/per-user pending export limit/, &Config.validate!/0
  end

  test "rejects malformed exact-host S3 allowlists" do
    for host <- ["https://s3.example.com", "*.example.com", "s3.example.com.", "127.0.0.1"] do
      Application.put_env(:whisperlogs, :s3_allowed_hosts, [host])
      assert_raise ArgumentError, ~r/invalid S3 allowlist hostname/, &Config.validate!/0
    end
  end

  test "requires an alert cycle to include query cleanup time" do
    limits = Config.alert_limits()

    Application.put_env(
      :whisperlogs,
      :alert_limits,
      Map.put(limits, :cycle_timeout_ms, limits.query_timeout_ms)
    )

    assert_raise ArgumentError, ~r/query timeout plus 1000ms cleanup/, &Config.validate!/0
  end

  test "rejects clustering configuration" do
    Application.put_env(:whisperlogs, :dns_cluster_query, "whisperlogs.internal")
    assert_raise ArgumentError, ~r/DNS_CLUSTER_QUERY is unsupported/, &Config.validate!/0
  end
end
