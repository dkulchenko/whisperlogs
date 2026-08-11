defmodule WhisperLogs.OAuthFixtures do
  @moduledoc false

  alias WhisperLogs.Accounts.Scope
  alias WhisperLogs.OAuth
  alias WhisperLogs.OAuth.Client

  def oauth_client_fixture(attrs \\ %{}) do
    metadata =
      Map.merge(
        %{
          "client_name" => "Codex test client",
          "redirect_uris" => ["http://127.0.0.1:45678/callback"],
          "grant_types" => ["authorization_code", "refresh_token"],
          "response_types" => ["code"],
          "token_endpoint_auth_method" => "none"
        },
        attrs
      )

    {:ok, client} = Client.register(metadata)
    client
  end

  def oauth_credentials_fixture(user, attrs \\ %{}) do
    client = Map.get_lazy(attrs, :client, &oauth_client_fixture/0)
    verifier = Map.get(attrs, :verifier, String.duplicate("v", 64))
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    request = %{
      client_id: client.client_id,
      client_name: client.client_name,
      redirect_uri: hd(client.redirect_uris),
      code_challenge: challenge,
      scope: OAuth.scope(),
      resource: OAuth.resource(),
      state: "test-state"
    }

    {:ok, code} = OAuth.authorize(Scope.for_user(user), request)

    {:ok, credentials} =
      OAuth.exchange_authorization_code(%{
        "code" => code,
        "client_id" => client.client_id,
        "redirect_uri" => request.redirect_uri,
        "code_verifier" => verifier,
        "resource" => OAuth.resource()
      })

    %{client: client, request: request, credentials: credentials}
  end
end
