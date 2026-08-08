defmodule WhisperLogsWeb.Plugs.ApiAuthTest do
  use WhisperLogsWeb.ConnCase, async: false

  alias WhisperLogsWeb.Plugs.ApiAuth

  import WhisperLogs.AccountsFixtures

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
    end

    test "assigns correct source name from http_source", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user, source: "custom-source-name")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> ApiAuth.call([])

      assert conn.assigns[:source] == "custom-source-name"
    end

    test "does not mutate the authenticated source", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)
      scope = WhisperLogs.Accounts.Scope.for_user(user)

      conn
      |> put_req_header("authorization", "Bearer #{source.key}")
      |> ApiAuth.call([])

      updated_source = WhisperLogs.Accounts.get_source(scope, source.id)
      assert updated_source.updated_at == source.updated_at
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

      # Second request (new conn since conn is immutable)
      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{source.key}")
        |> ApiAuth.call([])

      refute conn2.halted
      assert conn2.assigns[:http_source].id == source.id
    end

    test "rejects token from revoked source", %{conn: conn} do
      user = user_fixture()
      source = http_source_fixture(user)

      # Revoke the source
      scope = WhisperLogs.Accounts.Scope.for_user(user)
      {:ok, _revoked} = WhisperLogs.Accounts.revoke_source(scope, source.id)

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
