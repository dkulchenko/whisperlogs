defmodule WhisperLogs.MCPTest do
  use WhisperLogs.DataCase, async: true

  alias WhisperLogs.Accounts.Scope
  alias WhisperLogs.MCP

  import WhisperLogs.AccountsFixtures
  import WhisperLogs.LogsFixtures

  test "exposes exactly one read-only search tool" do
    assert %{"tools" => [tool]} = MCP.tools_result()
    assert tool["name"] == "search_logs"
    assert tool["annotations"]["readOnlyHint"]
    refute tool["annotations"]["destructiveHint"]
  end

  test "searches and pages with a user- and query-bound cursor" do
    user = user_fixture()
    scope = Scope.for_user(user)
    log_fixture("api", message: "needle first")
    log_fixture("api", message: "needle second")

    assert {:ok, first} = MCP.call(scope, "search_logs", %{"query" => "needle", "limit" => 1})
    assert first["isError"] == false
    assert first["structuredContent"]["has_more"]
    assert [log] = first["structuredContent"]["logs"]
    assert String.contains?(log["message"], "needle")

    cursor = first["structuredContent"]["next_cursor"]

    assert {:ok, second} =
             MCP.call(scope, "search_logs", %{
               "query" => "needle",
               "limit" => 1,
               "cursor" => cursor
             })

    assert [second_log] = second["structuredContent"]["logs"]
    refute second_log["id"] == log["id"]

    assert {:ok, invalid} =
             MCP.call(scope, "search_logs", %{"query" => "different", "cursor" => cursor})

    assert invalid["isError"]

    other_scope = user_fixture() |> Scope.for_user()

    assert {:ok, wrong_user} =
             MCP.call(other_scope, "search_logs", %{"query" => "needle", "cursor" => cursor})

    assert wrong_user["isError"]
  end

  test "rejects nonblank queries that parse to no valid tokens" do
    scope = user_fixture() |> Scope.for_user()

    assert {:ok, result} = MCP.call(scope, "search_logs", %{"query" => "!!!"})
    assert result["isError"]
  end

  test "supports full RFC 3339 query filters and structured time bounds" do
    scope = user_fixture() |> Scope.for_user()

    old =
      log_fixture("api",
        message: "checkout old",
        timestamp: ~U[2026-08-12 00:00:00.000000Z]
      )

    recent =
      log_fixture("api",
        message: "checkout recent",
        timestamp: ~U[2026-08-12 01:00:00.000000Z],
        metadata: %{"request_path" => "/checkout"}
      )

    assert {:ok, query_result} =
             MCP.call(scope, "search_logs", %{
               "query" => "timestamp:>=2026-08-12T00:15:00Z metadata.request_path:/checkout"
             })

    assert [%{"id" => recent_id}] = query_result["structuredContent"]["logs"]
    assert recent_id == recent.id
    refute recent_id == old.id

    assert {:ok, structured_result} =
             MCP.call(scope, "search_logs", %{
               "since" => "2026-08-12T00:15:00Z",
               "until" => "2026-08-12T02:00:00Z"
             })

    assert [%{"id" => ^recent_id}] = structured_result["structuredContent"]["logs"]
  end

  test "validates structured time bounds and binds them to cursors" do
    scope = user_fixture() |> Scope.for_user()
    log_fixture("api", timestamp: ~U[2026-08-12 01:00:00.000000Z])
    log_fixture("api", timestamp: ~U[2026-08-12 01:30:00.000000Z])

    assert {:ok, first} =
             MCP.call(scope, "search_logs", %{
               "since" => "2026-08-12T00:15:00Z",
               "limit" => 1
             })

    cursor = first["structuredContent"]["next_cursor"]
    assert is_binary(cursor)

    assert {:ok, invalid_cursor} =
             MCP.call(scope, "search_logs", %{
               "since" => "2026-08-12T01:15:00Z",
               "limit" => 1,
               "cursor" => cursor
             })

    assert invalid_cursor["isError"]

    assert {:ok, invalid_range} =
             MCP.call(scope, "search_logs", %{
               "since" => "2026-08-12T02:00:00Z",
               "until" => "2026-08-12T01:00:00Z"
             })

    assert invalid_range["isError"]

    assert {:ok, invalid_datetime} =
             MCP.call(scope, "search_logs", %{"since" => "one hour ago"})

    assert invalid_datetime["isError"]
  end

  test "describes structured time fields and concrete query examples" do
    assert %{"tools" => [%{"inputSchema" => schema, "description" => description}]} =
             MCP.tools_result()

    assert schema["properties"]["since"]["format"] == "date-time"
    assert schema["properties"]["until"]["format"] == "date-time"
    assert schema["properties"]["query"]["default"] == ""
    assert description =~ "timestamp:>=2026-08-12T00:15:00Z"
    assert description =~ ~s(request_path:"/checkout")
  end
end
