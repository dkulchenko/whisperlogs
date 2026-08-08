defmodule WhisperLogs.Syslog.ListenerTest do
  use WhisperLogs.DataCase, async: false

  alias WhisperLogs.Syslog.Listener
  alias WhisperLogs.Logs

  setup do
    {:ok, port: available_port()}
  end

  defp available_port(attempts \\ 100)
  defp available_port(0), do: raise("could not find an available TCP/UDP port")

  defp available_port(attempts) do
    {:ok, tcp_socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(tcp_socket)

    case :gen_udp.open(port, [:binary]) do
      {:ok, udp_socket} ->
        :gen_udp.close(udp_socket)
        :gen_tcp.close(tcp_socket)
        port

      {:error, _reason} ->
        :gen_tcp.close(tcp_socket)
        available_port(attempts - 1)
    end
  end

  # Create a mock source struct for testing
  defp mock_source(opts) do
    %{
      id: Keyword.get(opts, :id, Ecto.UUID.generate()),
      source: Keyword.get(opts, :source, "test-syslog-source"),
      port: Keyword.fetch!(opts, :port),
      transport: Keyword.get(opts, :transport, "udp"),
      allowed_hosts: Keyword.get(opts, :allowed_hosts, []),
      admission_mode: Keyword.get(opts, :admission_mode, "any"),
      tls_framing: Keyword.get(opts, :tls_framing),
      tls_client_identities: Keyword.get(opts, :tls_client_identities, [])
    }
  end

  describe "UDP listener" do
    test "abnormal ingest exits release per-source and global queue admission", %{port: port} do
      old_limits = Application.fetch_env!(:whisperlogs, :syslog_limits)

      Application.put_env(
        :whisperlogs,
        :syslog_limits,
        old_limits |> Map.put(:max_queued_per_source, 1) |> Map.put(:max_queued_global, 1)
      )

      on_exit(fn -> Application.put_env(:whisperlogs, :syslog_limits, old_limits) end)
      test_pid = self()

      ingest_fun = fn _source, _frame ->
        send(test_pid, {:ingest_worker, self()})
        receive do: (:crash -> exit(:forced_ingest_failure))
      end

      source = mock_source(port: port, transport: "udp")

      {:ok, listener} =
        start_supervised({Listener, source: source, ingest_fun: ingest_fun})

      assert :ok = GenServer.call(listener, {:frame, "first"})
      assert_receive {:ingest_worker, first_worker}
      first_ref = Process.monitor(first_worker)
      send(first_worker, :crash)
      assert_receive {:DOWN, ^first_ref, :process, ^first_worker, :forced_ingest_failure}
      wait_for_ingest_count(listener, 0)
      _ = :sys.get_state(WhisperLogs.Syslog.Limits)

      assert :ok = GenServer.call(listener, {:frame, "second"})
      assert_receive {:ingest_worker, second_worker}
      send(second_worker, :crash)
    end

    test "listener termination cancels ingest work and releases every reservation", %{port: port} do
      old_limits = Application.fetch_env!(:whisperlogs, :syslog_limits)

      Application.put_env(
        :whisperlogs,
        :syslog_limits,
        old_limits |> Map.put(:max_queued_per_source, 1) |> Map.put(:max_queued_global, 1)
      )

      on_exit(fn -> Application.put_env(:whisperlogs, :syslog_limits, old_limits) end)
      test_pid = self()

      ingest_fun = fn _source, _frame ->
        send(test_pid, {:blocked_ingest_worker, self()})
        receive do: (:finish -> :ok)
      end

      source = mock_source(port: port, transport: "udp")

      {:ok, listener} =
        start_supervised({Listener, source: source, ingest_fun: ingest_fun})

      assert :ok = GenServer.call(listener, {:frame, "reserved"})
      assert_receive {:blocked_ingest_worker, worker}
      worker_ref = Process.monitor(worker)
      stop_supervised(Listener)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 1_000
      _ = :sys.get_state(WhisperLogs.Syslog.Limits)

      replacement = mock_source(port: port, transport: "udp")

      {:ok, replacement_listener} =
        start_supervised({Listener, source: replacement, ingest_fun: ingest_fun})

      assert :ok = GenServer.call(replacement_listener, {:frame, "capacity-restored"})
      assert_receive {:blocked_ingest_worker, replacement_worker}
      send(replacement_worker, :finish)
    end

    test "starts and listens on configured port", %{port: port} do
      source = mock_source(port: port, transport: "udp")

      {:ok, pid} = start_supervised({Listener, source: source})

      assert [{^pid, _}] = Registry.lookup(WhisperLogs.Syslog.Registry, source.id)

      # Verify port is actually open by checking socket
      # The listener should have bound the port
      assert {:error, :eaddrinuse} = :gen_udp.open(port)
    end

    test "parses received UDP messages and inserts logs", %{port: port} do
      source = mock_source(port: port, transport: "udp", source: "udp-test-#{port}")

      {:ok, _pid} = start_supervised({Listener, source: source})
      :ok = Logs.subscribe()

      # Send a syslog message via UDP
      {:ok, socket} = :gen_udp.open(0)
      message = "<34>Oct 11 22:14:15 testhost test: Hello from UDP"
      :gen_udp.send(socket, ~c"127.0.0.1", port, message)
      :gen_udp.close(socket)

      assert_receive {:new_logs, [_log]}, 1_000

      # Verify log was inserted
      logs = Logs.list_logs(sources: [source.source], limit: 10)
      assert length(logs) >= 1
      assert hd(logs).message =~ "Hello from UDP"
    end

    test "respects allowed_hosts when configured", %{port: port} do
      source =
        mock_source(
          port: port,
          transport: "udp",
          source: "allowed-hosts-test-#{port}",
          allowed_hosts: ["192.168.1.1"],
          admission_mode: "allowlist"
        )

      {:ok, _pid} = start_supervised({Listener, source: source})
      :ok = Logs.subscribe()

      # Send from localhost which is NOT in allowed_hosts
      {:ok, socket} = :gen_udp.open(0)
      message = "<34>Oct 11 22:14:15 testhost test: Should be rejected"
      :gen_udp.send(socket, ~c"127.0.0.1", port, message)
      :gen_udp.close(socket)

      refute_receive {:new_logs, _logs}, 100

      # Should NOT have inserted the log
      logs = Logs.list_logs(sources: [source.source], limit: 10)
      assert logs == []
    end

    test "accepts all hosts in any admission mode", %{port: port} do
      source =
        mock_source(
          port: port,
          transport: "udp",
          source: "auto-register-test-#{port}",
          allowed_hosts: ["192.168.1.1"],
          admission_mode: "any"
        )

      {:ok, _pid} = start_supervised({Listener, source: source})
      :ok = Logs.subscribe()

      # Send from localhost - should be accepted despite not being in allowed_hosts
      {:ok, socket} = :gen_udp.open(0)
      message = "<34>Oct 11 22:14:15 testhost test: Should be accepted"
      :gen_udp.send(socket, ~c"127.0.0.1", port, message)
      :gen_udp.close(socket)

      assert_receive {:new_logs, [_log]}, 1_000

      logs = Logs.list_logs(sources: [source.source], limit: 10)
      assert length(logs) >= 1
    end
  end

  describe "TCP listener" do
    test "starts and listens on configured port", %{port: port} do
      source = mock_source(port: port, transport: "tcp")

      {:ok, pid} = start_supervised({Listener, source: source})

      assert [{^pid, _}] = Registry.lookup(WhisperLogs.Syslog.Registry, source.id)

      # Verify we can connect to the TCP port
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary])
      :gen_tcp.close(socket)
    end

    test "accepts TCP connections and parses line-delimited messages", %{port: port} do
      source = mock_source(port: port, transport: "tcp", source: "tcp-test-#{port}")

      {:ok, _pid} = start_supervised({Listener, source: source})
      :ok = Logs.subscribe()

      # Connect and send a syslog message
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line])
      message = "<34>Oct 11 22:14:15 testhost test: Hello from TCP\n"
      :gen_tcp.send(socket, message)
      :gen_tcp.close(socket)

      assert_receive {:new_logs, [_log]}, 1_000

      logs = Logs.list_logs(sources: [source.source], limit: 10)
      assert length(logs) >= 1
      assert hd(logs).message =~ "Hello from TCP"
    end

    test "handles connection close gracefully", %{port: port} do
      source = mock_source(port: port, transport: "tcp")

      {:ok, pid} = start_supervised({Listener, source: source})

      # Connect and immediately close
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary])
      :gen_tcp.close(socket)

      # Listener should still be running
      assert [{^pid, _}] = Registry.lookup(WhisperLogs.Syslog.Registry, source.id)
    end

    test "policy replacement synchronously closes established connections", %{port: port} do
      source = mock_source(port: port, transport: "tcp", admission_mode: "any")
      {:ok, listener} = start_supervised({Listener, source: source})
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      wait_for_connection_count(listener, 1)

      replacement = %{source | admission_mode: "allowlist", allowed_hosts: []}
      assert :ok = GenServer.call(listener, {:replace_policy, replacement})
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
      wait_for_connection_count(listener, 0)
    end
  end

  describe "both transport mode" do
    test "starts both UDP and TCP listeners", %{port: port} do
      source = mock_source(port: port, transport: "both")

      {:ok, pid} = start_supervised({Listener, source: source})

      assert [{^pid, _}] = Registry.lookup(WhisperLogs.Syslog.Registry, source.id)

      # Both ports should be bound - UDP will fail because port is in use
      assert {:error, :eaddrinuse} = :gen_udp.open(port)

      # TCP should accept connections
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary])
      :gen_tcp.close(socket)
    end

    test "handles messages on both transports", %{port: port} do
      source = mock_source(port: port, transport: "both", source: "both-test-#{port}")

      {:ok, _pid} = start_supervised({Listener, source: source})
      :ok = Logs.subscribe()

      # Send via UDP
      {:ok, udp_socket} = :gen_udp.open(0)
      udp_message = "<34>Oct 11 22:14:15 testhost test: UDP message"
      :gen_udp.send(udp_socket, ~c"127.0.0.1", port, udp_message)
      :gen_udp.close(udp_socket)

      # Send via TCP
      {:ok, tcp_socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line])
      tcp_message = "<34>Oct 11 22:14:15 testhost test: TCP message\n"
      :gen_tcp.send(tcp_socket, tcp_message)
      :gen_tcp.close(tcp_socket)

      assert_receive {:new_logs, [_log]}, 1_000
      assert_receive {:new_logs, [_log]}, 1_000

      logs = Logs.list_logs(sources: [source.source], limit: 10)
      messages = Enum.map(logs, & &1.message)

      assert Enum.any?(messages, &(&1 =~ "UDP message"))
      assert Enum.any?(messages, &(&1 =~ "TCP message"))
    end
  end

  describe "host filtering" do
    test "rejects messages from non-allowed hosts", %{port: port} do
      source =
        mock_source(
          port: port,
          transport: "udp",
          source: "reject-test-#{port}",
          allowed_hosts: ["10.0.0.1"],
          admission_mode: "allowlist"
        )

      {:ok, _pid} = start_supervised({Listener, source: source})
      :ok = Logs.subscribe()

      # 127.0.0.1 is not in allowed list
      {:ok, socket} = :gen_udp.open(0)
      :gen_udp.send(socket, ~c"127.0.0.1", port, "<34>Oct 11 22:14:15 host test")
      :gen_udp.close(socket)

      refute_receive {:new_logs, _logs}, 100

      logs = Logs.list_logs(sources: [source.source], limit: 10)
      assert logs == []
    end

    test "accepts messages from allowed hosts", %{port: port} do
      source =
        mock_source(
          port: port,
          transport: "udp",
          source: "accept-test-#{port}",
          allowed_hosts: ["127.0.0.1"],
          admission_mode: "allowlist"
        )

      {:ok, _pid} = start_supervised({Listener, source: source})
      :ok = Logs.subscribe()

      {:ok, socket} = :gen_udp.open(0)
      :gen_udp.send(socket, ~c"127.0.0.1", port, "<34>Oct 11 22:14:15 host test: Allowed")
      :gen_udp.close(socket)

      assert_receive {:new_logs, [_log]}, 1_000

      logs = Logs.list_logs(sources: [source.source], limit: 10)
      assert length(logs) >= 1
    end

    test "denies all when an allowlist is empty", %{port: port} do
      source =
        mock_source(
          port: port,
          transport: "udp",
          source: "empty-hosts-test-#{port}",
          allowed_hosts: [],
          admission_mode: "allowlist"
        )

      {:ok, _pid} = start_supervised({Listener, source: source})
      :ok = Logs.subscribe()

      {:ok, socket} = :gen_udp.open(0)
      :gen_udp.send(socket, ~c"127.0.0.1", port, "<34>Oct 11 22:14:15 host test: Empty allowed")
      :gen_udp.close(socket)

      refute_receive {:new_logs, _logs}, 100

      logs = Logs.list_logs(sources: [source.source], limit: 10)
      assert logs == []
    end
  end

  describe "process lifecycle" do
    test "cleans up sockets on termination", %{port: port} do
      source = mock_source(port: port, transport: "udp")

      {:ok, _pid} = start_supervised({Listener, source: source})

      # Port is in use
      assert {:error, :eaddrinuse} = :gen_udp.open(port)

      # Stop the listener
      stop_supervised(Listener)

      # Port should now be available
      {:ok, socket} = :gen_udp.open(port)
      :gen_udp.close(socket)
    end

    test "registers in Registry with source_id", %{port: port} do
      source = mock_source(port: port, transport: "udp")

      {:ok, _pid} = start_supervised({Listener, source: source})

      # Should be findable in registry
      result = Registry.lookup(WhisperLogs.Syslog.Registry, source.id)
      assert length(result) == 1
    end
  end

  defp wait_for_ingest_count(listener, expected) do
    Enum.reduce_while(1..1_000, nil, fn _, _ ->
      state = :sys.get_state(listener)

      if state.outstanding == expected,
        do: {:halt, :ok},
        else: {:cont, nil}
    end) || flunk("listener did not reach outstanding count #{expected}")
  end

  defp wait_for_connection_count(listener, expected) do
    Enum.reduce_while(1..1_000, nil, fn _, _ ->
      state = :sys.get_state(listener)

      if MapSet.size(state.connections) == expected,
        do: {:halt, :ok},
        else: {:cont, nil}
    end) || flunk("listener did not reach connection count #{expected}")
  end
end
