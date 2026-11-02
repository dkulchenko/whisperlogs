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

    test "accepts timestamps of any RFC 3339 precision", %{conn: conn} do
      source = http_source_fixture(user_fixture())

      logs =
        for timestamp <- [
              "2026-11-02T03:32:37Z",
              "2026-11-02T03:32:37.27493Z",
              "2026-11-02T03:32:37.123456789Z"
            ],
            do: %{"timestamp" => timestamp}

      conn = post_logs(conn, source, Jason.encode!(%{"logs" => logs}))

      assert json_response(conn, 200)["count"] == 3
    end

    test "explains malformed JSON with a 400", %{conn: conn} do
      source = http_source_fixture(user_fixture())

      {400, _headers, body} =
        assert_error_sent(400, fn -> post_logs(conn, source, ~s({"logs": [)) end)

      assert %{"errors" => %{"detail" => "Bad Request", "message" => message}} =
               Jason.decode!(body)

      assert message =~ "unexpected end of input"
    end

    test "rejects a whole batch for one invalid event and names it", %{conn: conn} do
      source = http_source_fixture(user_fixture())
      before_count = Logs.count_logs()

      body =
        Jason.encode!(%{"logs" => [%{"message" => "valid"}, %{"timestamp" => "yesterday"}]})

      conn = post_logs(conn, source, body)

      assert json_response(conn, 422)["error"] == %{
               "field" => "timestamp",
               "index" => 1,
               "reason" => "invalid_rfc3339"
             }

      assert Logs.count_logs() == before_count
    end

    @tag :postgres_only
    test "rejects NUL characters with 422 on PostgreSQL", %{conn: conn} do
      source = http_source_fixture(user_fixture())

      conn = post_logs(conn, source, ~S({"logs":[{"metadata":{"a":"b\u0000"}}]}))

      assert json_response(conn, 422)["error"]["reason"] == "contains_nul"
    end

    test "rejects uploads in a multipart body with 422", %{conn: conn} do
      source = http_source_fixture(user_fixture())

      for name <- ["logs[]", "logs[][message]", "logs[][metadata]", "logs[][metadata][key]"] do
        body =
          "--b\r\nContent-Disposition: form-data; name=\"#{name}\"; filename=\"f.txt\"\r\n" <>
            "Content-Type: text/plain\r\n\r\nhello\r\n--b--\r\n"

        response =
          conn
          |> put_req_header("content-type", "multipart/form-data; boundary=b")
          |> put_req_header("authorization", "Bearer #{source.key}")
          |> Phoenix.ConnTest.dispatch(@endpoint, :post, "/api/v1/logs", body)

        assert response.status == 422
      end
    end

    test "treats token bytes the database refuses as an invalid key", %{conn: conn} do
      for token <- [<<0xFF, 0xFE>>, "a\0b"] do
        response =
          conn
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer " <> token)
          |> post("/api/v1/logs", %{"logs" => []})

        assert json_response(response, 401)["error"] == "Invalid or missing API key"
      end
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

  defp post_logs(conn, source, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{source.key}")
    |> Phoenix.ConnTest.dispatch(@endpoint, :post, "/api/v1/logs", body)
  end
end
