defmodule WhisperLogs.LogsTest do
  use WhisperLogs.DataCase

  alias WhisperLogs.Logs

  describe "search with level filter" do
    setup do
      # Insert test logs with different levels
      Logs.insert_batch("test-source", [
        %{"level" => "debug", "message" => "debug message"},
        %{"level" => "info", "message" => "info message"},
        %{"level" => "warning", "message" => "warning message"},
        %{"level" => "error", "message" => "error message"}
      ])

      :ok
    end

    test "filters by level" do
      logs = Logs.list_logs(search: "level:error")
      assert length(logs) == 1
      assert hd(logs).level == "error"
    end

    test "filters by level alias" do
      logs = Logs.list_logs(search: "level:err")
      assert length(logs) == 1
      assert hd(logs).level == "error"
    end

    test "excludes by level" do
      logs = Logs.list_logs(search: "-level:debug")
      assert length(logs) == 3
      refute Enum.any?(logs, &(&1.level == "debug"))
    end

    test "excludes multiple levels" do
      logs = Logs.list_logs(search: "-level:debug -level:info")
      assert length(logs) == 2
      refute Enum.any?(logs, &(&1.level == "debug"))
      refute Enum.any?(logs, &(&1.level == "info"))
    end
  end

  describe "search with timestamp filter" do
    setup do
      now = DateTime.utc_now()
      old = DateTime.add(now, -2, :hour)
      very_old = DateTime.add(now, -2, :day)

      # Insert logs with different timestamps
      Logs.insert_batch("test-source", [
        %{"timestamp" => DateTime.to_iso8601(very_old), "message" => "very old message"},
        %{"timestamp" => DateTime.to_iso8601(old), "message" => "old message"},
        %{"timestamp" => DateTime.to_iso8601(now), "message" => "new message"}
      ])

      :ok
    end

    test "filters by timestamp with gt operator" do
      logs = Logs.list_logs(search: "timestamp:>-1h")
      assert length(logs) == 1
      assert hd(logs).message == "new message"
    end

    test "filters by timestamp with gte operator" do
      logs = Logs.list_logs(search: "timestamp:>=-1d")
      assert length(logs) == 2
      refute Enum.any?(logs, &(&1.message == "very old message"))
    end

    test "filters by timestamp with lt operator" do
      logs = Logs.list_logs(search: "timestamp:<-1h")
      assert length(logs) == 2
      refute Enum.any?(logs, &(&1.message == "new message"))
    end

    test "excludes by timestamp" do
      logs = Logs.list_logs(search: "-timestamp:<-1d")
      # Should exclude logs older than 1 day (keep only recent ones)
      refute Enum.any?(logs, &(&1.message == "very old message"))
    end
  end

  describe "search with source filter" do
    setup do
      Logs.insert_batch("production-api", [%{"message" => "prod message"}])
      Logs.insert_batch("staging-api", [%{"message" => "staging message"}])
      Logs.insert_batch("test-runner", [%{"message" => "test message"}])
      :ok
    end

    test "filters by source pattern" do
      logs = Logs.list_logs(search: "source:prod")
      assert length(logs) == 1
      assert hd(logs).source == "production-api"
    end

    test "filters by partial source match" do
      logs = Logs.list_logs(search: "source:api")
      assert length(logs) == 2
      sources = Enum.map(logs, & &1.source)
      assert "production-api" in sources
      assert "staging-api" in sources
    end

    test "excludes by source pattern" do
      logs = Logs.list_logs(search: "-source:test")
      assert length(logs) == 2
      refute Enum.any?(logs, &(&1.source == "test-runner"))
    end
  end

  describe "combined special filters" do
    setup do
      now = DateTime.utc_now()
      old = DateTime.add(now, -2, :hour)

      Logs.insert_batch("production-api", [
        %{
          "level" => "error",
          "timestamp" => DateTime.to_iso8601(now),
          "message" => "recent prod error"
        },
        %{
          "level" => "info",
          "timestamp" => DateTime.to_iso8601(now),
          "message" => "recent prod info"
        },
        %{
          "level" => "error",
          "timestamp" => DateTime.to_iso8601(old),
          "message" => "old prod error"
        }
      ])

      Logs.insert_batch("test-runner", [
        %{
          "level" => "error",
          "timestamp" => DateTime.to_iso8601(now),
          "message" => "recent test error"
        }
      ])

      :ok
    end

    test "combines level and timestamp filters" do
      logs = Logs.list_logs(search: "level:error timestamp:>-1h")
      assert length(logs) == 2
      assert Enum.all?(logs, &(&1.level == "error"))
      assert Enum.all?(logs, &(DateTime.diff(DateTime.utc_now(), &1.timestamp, :hour) < 2))
    end

    test "combines level and source filters" do
      logs = Logs.list_logs(search: "level:error source:prod")
      assert length(logs) == 2
      assert Enum.all?(logs, &(&1.level == "error"))
      assert Enum.all?(logs, &String.contains?(&1.source, "prod"))
    end

    test "combines all three special filters" do
      logs = Logs.list_logs(search: "level:error timestamp:>-1h source:prod")
      assert length(logs) == 1
      log = hd(logs)
      assert log.level == "error"
      assert log.source == "production-api"
      assert log.message == "recent prod error"
    end

    test "combines special filters with exclusions" do
      logs = Logs.list_logs(search: "level:error -source:test")
      assert length(logs) == 2
      assert Enum.all?(logs, &(&1.level == "error"))
      refute Enum.any?(logs, &String.contains?(&1.source, "test"))
    end
  end

  describe "special filters with regular metadata" do
    setup do
      Logs.insert_batch("api", [
        %{
          "level" => "error",
          "message" => "request failed",
          "metadata" => %{"user_id" => "123", "status" => "500"}
        },
        %{
          "level" => "error",
          "message" => "auth failed",
          "metadata" => %{"user_id" => "456", "status" => "401"}
        },
        %{
          "level" => "info",
          "message" => "request succeeded",
          "metadata" => %{"user_id" => "123", "status" => "200"}
        }
      ])

      :ok
    end

    test "combines level filter with metadata filter" do
      logs = Logs.list_logs(search: "level:error user_id:123")
      assert length(logs) == 1
      assert hd(logs).message == "request failed"
    end

    test "combines source filter with metadata filter" do
      logs = Logs.list_logs(search: "source:api status:500")
      assert length(logs) == 1
      assert hd(logs).message == "request failed"
    end
  end

  describe "bounded batch validation" do
    test "rejects empty and excessive batches" do
      limits = WhisperLogs.Config.receiver_limits()

      assert {:error, %{field: :logs, reason: :empty}} = Logs.insert_batch("api", [])

      events = List.duplicate(%{"message" => "event"}, limits.max_batch_size + 1)

      assert {:error, %{field: :logs, reason: :too_many}} =
               Logs.insert_batch("api", events)
    end

    test "rejects a malformed event atomically with its index" do
      assert {:error, %{field: :level, reason: :invalid_value, index: 1}} =
               Logs.insert_batch("api", [
                 %{"message" => "valid"},
                 %{"message" => "invalid", "level" => "fatal"}
               ])

      assert Logs.list_logs(sources: ["api"]) == []
    end

    test "normalizes defaults and derives source authority from the caller" do
      assert {:ok, [log]} =
               Logs.insert_batch("trusted-source", [
                 %{
                   "level" => "warn",
                   "source" => "payload-source",
                   "request_id" => "req-1",
                   "metadata" => %{"source" => "metadata-source"}
                 }
               ])

      assert log.level == "warning"
      assert log.message == ""
      assert log.source == "trusted-source"
      assert log.metadata == %{"request_id" => "req-1", "source" => "metadata-source"}
      assert log.timestamp == log.inserted_at
    end

    test "measures UTF-8 bytes, metadata depth, and the merged request id" do
      with_receiver_limits(
        %{
          max_message_bytes: 4,
          max_metadata_bytes: 20,
          max_metadata_depth: 2,
          max_event_bytes: 200,
          max_request_bytes: 400
        },
        fn ->
          assert {:ok, [_log]} = Logs.insert_batch("api", [%{"message" => "éé"}])

          assert {:error, %{field: :message, reason: :too_large}} =
                   Logs.insert_batch("api", [%{"message" => "ééa"}])

          assert {:error, %{field: :metadata, reason: :too_deep}} =
                   Logs.insert_batch("api", [%{"metadata" => %{"a" => %{"b" => %{}}}}])

          assert {:error, %{field: :metadata, reason: :too_large}} =
                   Logs.insert_batch("api", [%{"request_id" => String.duplicate("x", 20)}])
        end
      )
    end

    test "publishes exactly one bounded event after a successful batch" do
      :ok = Logs.subscribe()

      assert {:ok, inserted} =
               Logs.insert_batch("api", [%{"message" => "one"}, %{"message" => "two"}])

      assert_receive {:new_logs, ^inserted}
      refute_receive {:new_logs, _other}
    end
  end

  describe "numeric metadata comparisons" do
    test "matches only native numbers and canonical bounded decimal strings" do
      assert {:ok, _logs} =
               Logs.insert_batch("api", [
                 %{"message" => "native", "metadata" => %{"duration" => 12.5}},
                 %{"message" => "string", "metadata" => %{"duration" => "13"}},
                 %{"message" => "boolean", "metadata" => %{"duration" => true}},
                 %{"message" => "malformed", "metadata" => %{"duration" => "13ms"}},
                 %{"message" => "array", "metadata" => %{"duration" => [14]}},
                 %{
                   "message" => "numeric-overflow",
                   "metadata" => %{
                     "duration" => "1e999999999999999999999999999999999999999"
                   }
                 },
                 %{
                   "message" => "long",
                   "metadata" => %{"duration" => String.duplicate("1", 129)}
                 }
               ])

      assert Logs.list_logs(search: "duration:>12") |> Enum.map(& &1.message) |> Enum.sort() ==
               ["native", "string"]

      assert Logs.list_logs(search: "-duration:>12") == []
    end
  end

  defp with_receiver_limits(overrides, fun) do
    old = Application.fetch_env!(:whisperlogs, :receiver_limits)
    Application.put_env(:whisperlogs, :receiver_limits, Map.merge(old, overrides))

    try do
      fun.()
    after
      Application.put_env(:whisperlogs, :receiver_limits, old)
    end
  end
end
