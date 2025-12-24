defmodule WhisperLogs.ShipperTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias WhisperLogs.Shipper

  setup do
    # Configure the shipper for testing
    Application.put_env(:whisperlogs_shipper, :endpoint, "http://localhost:9999/api/v1/logs")
    Application.put_env(:whisperlogs_shipper, :auth_token, "test_token")
    Application.put_env(:whisperlogs_shipper, :batch_size, 3)
    Application.put_env(:whisperlogs_shipper, :flush_interval_ms, 50_000)
    Application.put_env(:whisperlogs_shipper, :inline_tasks, true)

    test_pid = self()

    # Set up Req.Test stub for HTTP calls
    Application.put_env(:whisperlogs_shipper, :req_test_options, plug: {Req.Test, __MODULE__})

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:log_shipped, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"status": "ok"}))
    end)

    # Start TaskSupervisor and Shipper
    start_supervised!({Task.Supervisor, name: WhisperLogs.Shipper.TaskSupervisor})
    {:ok, pid} = start_supervised(Shipper)

    # Allow the Shipper process to use our stub
    Req.Test.allow(__MODULE__, self(), pid)

    on_exit(fn ->
      Application.delete_env(:whisperlogs_shipper, :req_test_options)
    end)

    {:ok, shipper_pid: pid}
  end

  describe "log/1" do
    test "buffers events until batch size reached" do
      Shipper.log(%{level: "info", message: "one", timestamp: ts(), metadata: %{}})
      Shipper.log(%{level: "info", message: "two", timestamp: ts(), metadata: %{}})

      # Should not have shipped yet (batch_size is 3)
      refute_received {:log_shipped, _}

      Shipper.log(%{level: "info", message: "three", timestamp: ts(), metadata: %{}})

      # Now it should ship
      assert_receive {:log_shipped, payload}, 1000
      assert length(payload["logs"]) == 3
      assert Enum.map(payload["logs"], & &1["message"]) == ["one", "two", "three"]
    end

    test "preserves event data in shipped logs" do
      event = %{
        level: "error",
        message: "Something went wrong",
        timestamp: "2024-01-15T10:30:00.000000Z",
        metadata: %{request_id: "abc123", user_id: 42}
      }

      Shipper.log(event)
      Shipper.log(%{level: "info", message: "filler1", timestamp: ts(), metadata: %{}})
      Shipper.log(%{level: "info", message: "filler2", timestamp: ts(), metadata: %{}})

      assert_receive {:log_shipped, payload}, 1000

      [first | _] = payload["logs"]
      assert first["level"] == "error"
      assert first["message"] == "Something went wrong"
      assert first["metadata"]["request_id"] == "abc123"
    end
  end

  describe "flush/0" do
    test "immediately ships buffered events" do
      Shipper.log(%{level: "info", message: "only one", timestamp: ts(), metadata: %{}})

      refute_received {:log_shipped, _}

      Shipper.flush()

      assert_receive {:log_shipped, payload}, 1000
      assert length(payload["logs"]) == 1
      assert hd(payload["logs"])["message"] == "only one"
    end

    test "does nothing when buffer is empty" do
      assert Shipper.flush() == :ok
      refute_received {:log_shipped, _}
    end
  end

  describe "automatic flush" do
    setup do
      # Stop any existing Shipper from the parent setup
      stop_supervised(Shipper)

      # Reconfigure with short flush interval
      Application.put_env(:whisperlogs_shipper, :batch_size, 100)
      Application.put_env(:whisperlogs_shipper, :flush_interval_ms, 50)

      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:log_shipped, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"status": "ok"}))
      end)

      {:ok, pid} = start_supervised(Shipper)
      Req.Test.allow(__MODULE__, self(), pid)

      :ok
    end

    test "flushes buffer after interval even when batch size not reached" do
      # Log 1 event (well below batch_size of 100)
      Shipper.log(%{level: "info", message: "timer test", timestamp: ts(), metadata: %{}})

      # Should not have shipped immediately
      refute_received {:log_shipped, _}

      # Wait for flush interval + margin
      assert_receive {:log_shipped, payload}, 200

      assert length(payload["logs"]) == 1
      assert hd(payload["logs"])["message"] == "timer test"
    end
  end

  describe "error recovery" do
    setup do
      stop_supervised(Shipper)

      Application.put_env(:whisperlogs_shipper, :batch_size, 2)
      Application.put_env(:whisperlogs_shipper, :flush_interval_ms, 50_000)

      :ok
    end

    test "continues operating after HTTP failure" do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      Req.Test.stub(__MODULE__, fn conn ->
        :counters.add(call_count, 1, 1)

        {:ok, body, conn} = Plug.Conn.read_body(conn)

        if :counters.get(call_count, 1) == 1 do
          # First call fails
          send(test_pid, :http_failed)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(500, ~s({"error": "server error"}))
        else
          # Subsequent calls succeed
          send(test_pid, {:log_shipped, Jason.decode!(body)})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, ~s({"status": "ok"}))
        end
      end)

      {:ok, pid} = start_supervised(Shipper)
      Req.Test.allow(__MODULE__, self(), pid)

      # Capture IO.warn output from error handling
      capture_io(:stderr, fn ->
        # First batch - will fail
        Shipper.log(%{level: "info", message: "batch1-1", timestamp: ts(), metadata: %{}})
        Shipper.log(%{level: "info", message: "batch1-2", timestamp: ts(), metadata: %{}})

        assert_receive :http_failed, 1000

        # Shipper should still be alive
        assert Process.alive?(pid)

        # Second batch - should succeed
        Shipper.log(%{level: "info", message: "batch2-1", timestamp: ts(), metadata: %{}})
        Shipper.log(%{level: "info", message: "batch2-2", timestamp: ts(), metadata: %{}})

        assert_receive {:log_shipped, payload}, 1000
        assert length(payload["logs"]) == 2
      end)
    end
  end

  defp ts do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
