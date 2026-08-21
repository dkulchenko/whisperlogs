defmodule WhisperLogsWeb.OAuthControllerTest do
  use WhisperLogsWeb.ConnCase, async: true

  alias WhisperLogs.OAuth

  import WhisperLogs.AccountsFixtures
  import WhisperLogs.OAuthFixtures

  test "publishes protected resource and authorization server metadata", %{conn: conn} do
    conn = get(conn, "/.well-known/oauth-protected-resource")

    assert %{"resource" => resource, "scopes_supported" => ["logs:read"]} =
             json_response(conn, 200)

    assert resource == OAuth.resource()

    conn = build_conn() |> get("/.well-known/oauth-authorization-server")
    metadata = json_response(conn, 200)
    assert metadata["client_id_metadata_document_supported"]
    assert metadata["authorization_response_iss_parameter_supported"]
    assert metadata["code_challenge_methods_supported"] == ["S256"]
  end

  test "registers a stateless public client", %{conn: conn} do
    conn =
      post(conn, "/oauth/register", %{
        "client_name" => "Codex",
        "redirect_uris" => ["http://127.0.0.1:45678/callback"],
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => "none"
      })

    assert %{"client_id" => "wl_dcr_" <> _token} = json_response(conn, 201)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "renders consent only in the authenticated browser scope", %{conn: conn} do
    client = oauth_client_fixture()
    verifier = String.duplicate("c", 64)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    path =
      "/oauth/authorize?" <>
        URI.encode_query(%{
          "response_type" => "code",
          "client_id" => client.client_id,
          "redirect_uri" => hd(client.redirect_uris),
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "scope" => OAuth.scope(),
          "resource" => OAuth.resource(),
          "state" => "state"
        })

    assert conn |> get(path) |> redirected_to(302) == "/users/log-in"

    conn = conn |> log_in_user(user_fixture()) |> get(path)
    assert html_response(conn, 200) =~ ~s(id="oauth-consent-form")
  end

  test "renders consent when a loopback client selects an ephemeral callback port", %{conn: conn} do
    client =
      oauth_client_fixture(%{
        "redirect_uris" => ["http://127.0.0.1/callback/codex-client"]
      })

    verifier = String.duplicate("p", 64)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    path =
      "/oauth/authorize?" <>
        URI.encode_query(%{
          "response_type" => "code",
          "client_id" => client.client_id,
          "redirect_uri" => "http://127.0.0.1:49152/callback/codex-client",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "scope" => OAuth.scope(),
          "resource" => OAuth.resource(),
          "state" => "state"
        })

    conn = conn |> log_in_user(user_fixture()) |> get(path)
    assert html_response(conn, 200) =~ ~s(id="oauth-consent-form")
  end

  test "approves consent and exchanges the one-use code", %{conn: conn} do
    user = user_fixture()
    client = oauth_client_fixture()
    verifier = String.duplicate("d", 64)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    request = %{
      client_id: client.client_id,
      client_name: client.client_name,
      redirect_uri: hd(client.redirect_uris),
      code_challenge: challenge,
      scope: OAuth.scope(),
      resource: OAuth.resource(),
      state: "round-trip-state"
    }

    authorization_request = OAuth.sign_authorization_request(request)

    conn =
      conn
      |> log_in_user(user)
      |> post("/oauth/authorize", %{
        "authorization_request" => authorization_request,
        "decision" => "allow"
      })

    redirect = conn |> get_resp_header("location") |> List.first() |> URI.parse()
    query = URI.decode_query(redirect.query)
    assert query["state"] == "round-trip-state"
    assert query["iss"] == OAuth.issuer()

    token_conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => query["code"],
        "client_id" => client.client_id,
        "redirect_uri" => request.redirect_uri,
        "code_verifier" => verifier,
        "resource" => OAuth.resource()
      })

    assert %{"access_token" => access_token, "refresh_token" => refresh_token} =
             json_response(token_conn, 200)

    assert is_binary(access_token)
    assert is_binary(refresh_token)
    assert get_resp_header(token_conn, "cache-control") == ["no-store"]
  end
end
