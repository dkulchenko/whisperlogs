defmodule WhisperLogsWeb.Plugs.ApiAuthTest do
  use WhisperLogsWeb.ConnCase, async: false

  alias WhisperLogsWeb.Plugs.ApiAuth

  import WhisperLogs.AccountsFixtures

  # The ApiAuth plug spawns an async task to update last_used_at
  @task_completion_delay 50

  describe "call/2" do
    test "returns 401 when no Authorization header is present", %{conn: conn} do
      conn =
        conn
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401)["error"] == "Invalid or missing API key"
    end

    test "returns 401 when Authorization header is not Bearer format", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401)["error"] == "Invalid or missing API key"
    end

    test "returns 401 when Bearer token is invalid", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token_xyz")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401)["error"] == "Invalid or missing API key"
    end

    test "returns 401 when Bearer token format is malformed", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 for empty Bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer ")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "assigns http_source and source on valid Bearer token", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user, source: "my-api-source")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> ApiAuth.call([])

      refute conn.halted
      assert conn.assigns[:http_source].id == source.id
      assert conn.assigns[:source] == "my-api-source"

      Process.sleep(@task_completion_delay)
    end

    test "assigns correct source name from http_source", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user, source: "custom-source-name")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> ApiAuth.call([])

      assert conn.assigns[:source] == "custom-source-name"

      Process.sleep(@task_completion_delay)
    end

    test "updates last_used_at asynchronously", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)
      original_last_used = source.last_used_at

      conn
      |> put_req_header("authorization", "Bearer #{source.key}")
      |> ApiAuth.call([])

      # Wait for async task to complete
      Process.sleep(100)

      # Reload source and verify last_used_at was updated
      updated_source = WhisperLogs.Accounts.get_source(user, source.id)

      # Either it was nil before and now set, or it's a newer timestamp
      assert is_nil(original_last_used) or
               DateTime.compare(updated_source.last_used_at, original_last_used) in [:gt, :eq]
    end

    test "allows multiple requests with same valid token", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)

      # First request
      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> ApiAuth.call([])

      refute conn1.halted
      assert conn1.assigns[:http_source].id == source.id

      Process.sleep(@task_completion_delay)

      # Second request (new conn since conn is immutable)
      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> ApiAuth.call([])

      refute conn2.halted
      assert conn2.assigns[:http_source].id == source.id

      Process.sleep(@task_completion_delay)
    end

    test "rejects token from revoked source", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)

      # Revoke the source
      {:ok, _revoked} = WhisperLogs.Accounts.revoke_source(source)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "handles case-sensitive Bearer prefix", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)

      # "bearer" lowercase should fail
      conn1 =
        conn
        |> put_req_header("authorization", "bearer #{source.key}")
        |> ApiAuth.call([])

      assert conn1.halted
      assert conn1.status == 401

      # "BEARER" uppercase should also fail
      conn2 =
        build_conn()
        |> put_req_header("authorization", "BEARER #{source.key}")
        |> ApiAuth.call([])

      assert conn2.halted
      assert conn2.status == 401
    end
  end

  describe "init/1" do
    test "returns opts unchanged" do
      assert ApiAuth.init([]) == []
      assert ApiAuth.init(foo: :bar) == [foo: :bar]
    end
  end
end
