defmodule WhisperLogs.Syslog.ListenerTest do
  use WhisperLogs.DataCase, async: false

  alias WhisperLogs.Syslog.Listener
  alias WhisperLogs.Logs

  # Use high ephemeral ports for test stability
  @base_test_port 55000

  setup do
    # Ensure we have a unique port for each test
    # Use parentheses to ensure correct precedence
    offset = rem(:erlang.unique_integer([:positive, :monotonic]), 1000)
    port = @base_test_port + offset
    {:ok, port: port}
  end

  # Create a mock source struct for testing
  defp mock_source(opts) do
    %{
      id: Keyword.get(opts, :id, Ecto.UUID.generate()),
      source: Keyword.get(opts, :source, "test-syslog-source"),
      port: Keyword.fetch!(opts, :port),
      transport: Keyword.get(opts, :transport, "udp"),
      allowed_hosts: Keyword.get(opts, :allowed_hosts, []),
      auto_register_hosts: Keyword.get(opts, :auto_register_hosts, true)
    }
  end

  describe "UDP listener" do
    test "starts and listens on configured port", %{port: port} do
      source = mock_source(port: port, transport: "udp")

      {:ok, pid} = start_supervised({Listener, source: source})

      assert Process.alive?(pid)

      # Verify port is actually open by checking socket
      # The listener should have bound the port
      assert {:error, :eaddrinuse} = :gen_udp.open(port)
    end

    test "parses received UDP messages and inserts logs", %{port: port} do
      source = mock_source(port: port, transport: "udp", source: "udp-test-#{port}")

      {:ok, _pid} = start_supervised({Listener, source: source})

      # Give the listener time to start
      Process.sleep(50)

      # Send a syslog message via UDP
      {:ok, socket} = :gen_udp.open(0)
      message = "<34>Oct 11 22:14:15 testhost test: Hello from UDP"
      :gen_udp.send(socket, ~c"127.0.0.1", port, message)
      :gen_udp.close(socket)

      # Wait for processing
      Process.sleep(100)

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
          auto_register_hosts: false
        )

      {:ok, _pid} = start_supervised({Listener, source: source})
      Process.sleep(50)

      # Send from localhost which is NOT in allowed_hosts
      {:ok, socket} = :gen_udp.open(0)
      message = "<34>Oct 11 22:14:15 testhost test: Should be rejected"
      :gen_udp.send(socket, ~c"127.0.0.1", port, message)
      :gen_udp.close(socket)

      Process.sleep(100)

      # Should NOT have inserted the log
      logs = Logs.list_logs(sources: [source.source], limit: 10)
      assert logs == []
    end

    test "accepts all hosts when auto_register_hosts is true", %{port: port} do
      source =
        mock_source(
          port: port,
          transport: "udp",
          source: "auto-register-test-#{port}",
          allowed_hosts: ["192.168.1.1"],
          auto_register_hosts: true
        )

      {:ok, _pid} = start_supervised({Listener, source: source})
      Process.sleep(50)

      # Send from localhost - should be accepted despite not being in allowed_hosts
      {:ok, socket} = :gen_udp.open(0)
      message = "<34>Oct 11 22:14:15 testhost test: Should be accepted"
      :gen_udp.send(socket, ~c"127.0.0.1", port, message)
      :gen_udp.close(socket)

      Process.sleep(100)

      logs = Logs.list_logs(sources: [source.source], limit: 10)
      assert length(logs) >= 1
    end
  end

  describe "TCP listener" do
    test "starts and listens on configured port", %{port: port} do
      source = mock_source(port: port, transport: "tcp")

      {:ok, pid} = start_supervised({Listener, source: source})

      assert Process.alive?(pid)

      # Verify we can connect to the TCP port
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary])
      :gen_tcp.close(socket)
    end

    test "accepts TCP connections and parses line-delimited messages", %{port: port} do
      source = mock_source(port: port, transport: "tcp", source: "tcp-test-#{port}")

      {:ok, _pid} = start_supervised({Listener, source: source})
      Process.sleep(50)

      # Connect and send a syslog message
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line])
      message = "<34>Oct 11 22:14:15 testhost test: Hello from TCP\n"
      :gen_tcp.send(socket, message)
      :gen_tcp.close(socket)

      Process.sleep(100)

      logs = Logs.list_logs(sources: [source.source], limit: 10)
      assert length(logs) >= 1
      assert hd(logs).message =~ "Hello from TCP"
    end

    test "handles connection close gracefully", %{port: port} do
      source = mock_source(port: port, transport: "tcp")

      {:ok, pid} = start_supervised({Listener, source: source})
      Process.sleep(50)

      # Connect and immediately close
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary])
      :gen_tcp.close(socket)

      Process.sleep(50)

      # Listener should still be running
      assert Process.alive?(pid)
    end
  end

  describe "both transport mode" do
    test "starts both UDP and TCP listeners", %{port: port} do
      source = mock_source(port: port, transport: "both")

      {:ok, pid} = start_supervised({Listener, source: source})
      Process.sleep(50)

      assert Process.alive?(pid)

      # Both ports should be bound - UDP will fail because port is in use
      assert {:error, :eaddrinuse} = :gen_udp.open(port)

      # TCP should accept connections
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary])
      :gen_tcp.close(socket)
    end

    test "handles messages on both transports", %{port: port} do
      source = mock_source(port: port, transport: "both", source: "both-test-#{port}")

      {:ok, _pid} = start_supervised({Listener, source: source})
      Process.sleep(50)

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

      Process.sleep(150)

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
          auto_register_hosts: false
        )

      {:ok, _pid} = start_supervised({Listener, source: source})
      Process.sleep(50)

      # 127.0.0.1 is not in allowed list
      {:ok, socket} = :gen_udp.open(0)
      :gen_udp.send(socket, ~c"127.0.0.1", port, "<34>Oct 11 22:14:15 host test")
      :gen_udp.close(socket)

      Process.sleep(100)

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
          auto_register_hosts: false
        )

      {:ok, _pid} = start_supervised({Listener, source: source})
      Process.sleep(50)

      {:ok, socket} = :gen_udp.open(0)
      :gen_udp.send(socket, ~c"127.0.0.1", port, "<34>Oct 11 22:14:15 host test: Allowed")
      :gen_udp.close(socket)

      Process.sleep(100)

      logs = Logs.list_logs(sources: [source.source], limit: 10)
      assert length(logs) >= 1
    end

    test "allows all when allowed_hosts is empty", %{port: port} do
      source =
        mock_source(
          port: port,
          transport: "udp",
          source: "empty-hosts-test-#{port}",
          allowed_hosts: [],
          auto_register_hosts: false
        )

      {:ok, _pid} = start_supervised({Listener, source: source})
      Process.sleep(50)

      {:ok, socket} = :gen_udp.open(0)
      :gen_udp.send(socket, ~c"127.0.0.1", port, "<34>Oct 11 22:14:15 host test: Empty allowed")
      :gen_udp.close(socket)

      Process.sleep(100)

      logs = Logs.list_logs(sources: [source.source], limit: 10)
      assert length(logs) >= 1
    end
  end

  describe "process lifecycle" do
    test "cleans up sockets on termination", %{port: port} do
      source = mock_source(port: port, transport: "udp")

      {:ok, _pid} = start_supervised({Listener, source: source})
      Process.sleep(50)

      # Port is in use
      assert {:error, :eaddrinuse} = :gen_udp.open(port)

      # Stop the listener
      stop_supervised(Listener)
      Process.sleep(50)

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
end
