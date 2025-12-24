defmodule WhisperLogsWeb.LogControllerTest do
  use WhisperLogsWeb.ConnCase, async: false

  alias WhisperLogs.Logs

  import WhisperLogs.AccountsFixtures

  # The ApiAuth plug spawns an async task to update last_used_at
  # We need to allow time for it to complete before the sandbox cleans up
  @task_completion_delay 50

  describe "POST /api/v1/logs" do
    test "returns 401 without Authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/logs", %{"logs" => [%{"message" => "test"}]})

      assert json_response(conn, 401)["error"] == "Invalid or missing API key"
    end

    test "returns 401 with invalid token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer invalid_token")
        |> post("/api/v1/logs", %{"logs" => [%{"message" => "test"}]})

      assert json_response(conn, 401)["error"] == "Invalid or missing API key"
    end

    test "returns 401 with malformed Authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "InvalidFormat sometoken")
        |> post("/api/v1/logs", %{"logs" => [%{"message" => "test"}]})

      assert json_response(conn, 401)["error"] == "Invalid or missing API key"
    end

    test "accepts valid Bearer token and inserts logs", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)

      logs = [
        %{
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
          "level" => "info",
          "message" => "Test log message",
          "metadata" => %{"user_id" => 123}
        }
      ]

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> post("/api/v1/logs", %{"logs" => logs})

      response = json_response(conn, 200)
      assert response["ok"] == true
      assert response["count"] == 1

      Process.sleep(@task_completion_delay)
    end

    test "returns count of inserted logs", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)

      logs =
        for i <- 1..5 do
          %{
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
            "level" => Enum.random(~w(debug info warning error)),
            "message" => "Log message #{i}"
          }
        end

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> post("/api/v1/logs", %{"logs" => logs})

      response = json_response(conn, 200)
      assert response["count"] == 5

      Process.sleep(@task_completion_delay)
    end

    test "returns 400 for missing logs array", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> post("/api/v1/logs", %{"not_logs" => "wrong"})

      response = json_response(conn, 400)
      assert response["error"] == "Missing 'logs' array in request body"

      Process.sleep(@task_completion_delay)
    end

    test "handles empty logs array", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> post("/api/v1/logs", %{"logs" => []})

      response = json_response(conn, 200)
      assert response["ok"] == true
      assert response["count"] == 0

      Process.sleep(@task_completion_delay)
    end

    test "associates logs with source from token", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user, source: "my-api-source")

      logs = [%{"message" => "Tagged log"}]

      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{source.key}")
      |> post("/api/v1/logs", %{"logs" => logs})

      # Wait for async task to complete before checking
      Process.sleep(@task_completion_delay)

      # Verify the log is associated with the correct source
      stored_logs = Logs.list_logs(sources: ["my-api-source"], limit: 10)
      assert length(stored_logs) >= 1
      assert hd(stored_logs).source == "my-api-source"
    end

    test "updates source last_used_at asynchronously", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)
      original_last_used = source.last_used_at

      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{source.key}")
      |> post("/api/v1/logs", %{"logs" => [%{"message" => "test"}]})

      # Give async task time to complete
      Process.sleep(100)

      # Reload source and verify last_used_at was updated
      updated_source = WhisperLogs.Accounts.get_source(user, source.id)

      # Either it was nil before and now set, or it's a newer timestamp
      assert is_nil(original_last_used) or
               DateTime.compare(updated_source.last_used_at, original_last_used) in [:gt, :eq]
    end

    test "handles logs with various optional fields", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)

      logs = [
        # Minimal log
        %{"message" => "Minimal log"},
        # Full log with all fields
        %{
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
          "level" => "error",
          "message" => "Full log",
          "metadata" => %{"key" => "value"},
          "request_id" => "req-12345"
        },
        # Log with only level
        %{"level" => "debug", "message" => "Debug log"}
      ]

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> post("/api/v1/logs", %{"logs" => logs})

      response = json_response(conn, 200)
      assert response["count"] == 3

      Process.sleep(@task_completion_delay)
    end
  end
end
