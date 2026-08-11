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
end
