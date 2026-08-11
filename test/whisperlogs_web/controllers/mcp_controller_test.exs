defmodule WhisperLogsWeb.McpControllerTest do
  use WhisperLogsWeb.ConnCase, async: true

  alias WhisperLogs.MCP

  import WhisperLogs.AccountsFixtures
  import WhisperLogs.LogsFixtures
  import WhisperLogs.OAuthFixtures

  test "challenges unauthenticated clients with protected resource metadata", %{conn: conn} do
    conn = post(conn, "/mcp", %{})
    assert json_response(conn, 401)["error"]["message"] == "Unauthorized"
    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ "resource_metadata="
    assert challenge =~ ~s(scope="logs:read")
  end

  test "discovers the stateless 2026-07-28 server", %{conn: conn} do
    user = user_fixture()
    %{credentials: credentials} = oauth_credentials_fixture(user)
    body = request("server/discover", %{})

    conn = mcp_post(conn, body, credentials["access_token"])
    result = json_response(conn, 200)["result"]

    assert result["supportedVersions"] == [MCP.protocol_version()]
    assert result["capabilities"] == %{"tools" => %{}}
    refute get_resp_header(conn, "mcp-session-id") != []
  end

  test "calls log search and validates mirrored headers", %{conn: conn} do
    user = user_fixture()
    %{credentials: credentials} = oauth_credentials_fixture(user)
    log_fixture("api", message: "controller needle")

    body =
      request("tools/call", %{"name" => "search_logs", "arguments" => %{"query" => "needle"}})

    conn = mcp_post(conn, body, credentials["access_token"], "search_logs")
    result = json_response(conn, 200)["result"]
    assert [log] = result["structuredContent"]["logs"]
    assert log["message"] == "controller needle"

    bad_conn = mcp_post(build_conn(), body, credentials["access_token"], "another_tool")
    assert json_response(bad_conn, 400)["error"]["code"] == -32_020
  end

  test "rejects unsupported protocol versions", %{conn: conn} do
    user = user_fixture()
    %{credentials: credentials} = oauth_credentials_fixture(user)
    body = request("server/discover", %{}, "2025-11-25")

    conn = mcp_post(conn, body, credentials["access_token"], nil, "2025-11-25")
    assert json_response(conn, 400)["error"]["code"] == -32_022
  end

  test "rejects foreign origins before processing MCP requests", %{conn: conn} do
    user = user_fixture()
    %{credentials: credentials} = oauth_credentials_fixture(user)
    body = request("server/discover", %{})

    conn =
      conn
      |> put_req_header("origin", "https://attacker.example")
      |> mcp_post(body, credentials["access_token"])

    assert json_response(conn, 403)["error"]["message"] == "Invalid Origin"
  end

  test "allows only POST on the MCP endpoint", %{conn: conn} do
    conn = get(conn, "/mcp")
    assert json_response(conn, 405)["error"]["code"] == -32_601
    assert get_resp_header(conn, "allow") == ["POST"]
  end

  defp request(method, params, version \\ MCP.protocol_version()) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => version,
      "io.modelcontextprotocol/clientInfo" => %{"name" => "test", "version" => "1.0"},
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp mcp_post(conn, body, token, name \\ nil, version \\ MCP.protocol_version()) do
    conn =
      conn
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("mcp-protocol-version", version)
      |> put_req_header("mcp-method", body["method"])

    conn = if name, do: put_req_header(conn, "mcp-name", name), else: conn
    post(conn, "/mcp", body)
  end
end
