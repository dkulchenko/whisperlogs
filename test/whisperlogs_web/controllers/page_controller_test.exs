defmodule WhisperLogsWeb.PageControllerTest do
  use WhisperLogsWeb.ConnCase

  # In SQLite mode, users are auto-authenticated (no redirect)
  @moduletag :postgres_only

  test "GET / redirects to login for unauthenticated users", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
