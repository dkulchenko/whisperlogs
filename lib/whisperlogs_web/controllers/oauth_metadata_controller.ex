defmodule WhisperLogsWeb.OAuthMetadataController do
  use WhisperLogsWeb, :controller

  alias WhisperLogs.OAuth

  def protected_resource(conn, _params) do
    json(conn, %{
      "resource" => OAuth.resource(),
      "authorization_servers" => [OAuth.issuer()],
      "scopes_supported" => [OAuth.scope()],
      "bearer_methods_supported" => ["header"]
    })
  end

  def authorization_server(conn, _params) do
    issuer = OAuth.issuer()

    json(conn, %{
      "issuer" => issuer,
      "authorization_endpoint" => issuer <> "/oauth/authorize",
      "token_endpoint" => issuer <> "/oauth/token",
      "registration_endpoint" => issuer <> "/oauth/register",
      "scopes_supported" => [OAuth.scope()],
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "token_endpoint_auth_methods_supported" => ["none"],
      "code_challenge_methods_supported" => ["S256"],
      "client_id_metadata_document_supported" => true,
      "authorization_response_iss_parameter_supported" => true
    })
  end
end
