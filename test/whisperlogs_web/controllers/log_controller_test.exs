defmodule WhisperLogsWeb.LogControllerTest do
  use WhisperLogsWeb.ConnCase, async: false

  alias WhisperLogs.Logs

  import WhisperLogs.AccountsFixtures

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
    end

    test "returns 422 for missing logs array", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> post("/api/v1/logs", %{"not_logs" => "wrong"})

      response = json_response(conn, 422)
      assert response["error"] == %{"field" => "logs", "reason" => "invalid_batch"}
    end

    test "returns 422 for a non-list logs value", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> post("/api/v1/logs", %{"logs" => %{"message" => "not a batch"}})

      assert json_response(conn, 422)["error"] == %{
               "field" => "logs",
               "reason" => "invalid_batch"
             }
    end

    test "rejects an empty logs array", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> post("/api/v1/logs", %{"logs" => []})

      assert %{"error" => %{"field" => "logs", "reason" => "empty"}} =
               json_response(conn, 413)
    end

    test "associates logs with source from token", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user, source: "my-api-source")

      logs = [%{"message" => "Tagged log"}]

      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{source.key}")
      |> post("/api/v1/logs", %{"logs" => logs})

      # Verify the log is associated with the correct source
      stored_logs = Logs.list_logs(sources: ["my-api-source"], limit: 10)
      assert length(stored_logs) >= 1
      assert hd(stored_logs).source == "my-api-source"
    end

    test "authentication does not mutate the source record", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)
      scope = WhisperLogs.Accounts.Scope.for_user(user)

      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{source.key}")
      |> post("/api/v1/logs", %{"logs" => [%{"message" => "test"}]})

      updated_source = WhisperLogs.Accounts.get_source(scope, source.id)
      assert updated_source.updated_at == source.updated_at
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
    end
  end
end
