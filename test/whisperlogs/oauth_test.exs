defmodule WhisperLogs.OAuthTest do
  use WhisperLogs.DataCase, async: true

  alias WhisperLogs.Accounts.Scope
  alias WhisperLogs.OAuth
  alias WhisperLogs.OAuth.Client
  alias WhisperLogs.OAuth.{AuthorizationCode, Token}

  import WhisperLogs.AccountsFixtures
  import WhisperLogs.OAuthFixtures

  test "stateless DCR accepts only safe public-client metadata" do
    assert {:error, :invalid_redirect_uris} =
             Client.register(%{
               "client_name" => "Bad client",
               "redirect_uris" => ["http://attacker.example/callback"]
             })

    client = oauth_client_fixture()
    assert {:ok, resolved} = Client.resolve(client.client_id)
    assert resolved.client_name == client.client_name
    assert {:error, :invalid_client} = Client.resolve(client.client_id <> "tampered")
    assert {:error, :invalid_client} = Client.resolve("https://127.0.0.1/client.json")
  end

  test "authorization codes require exact PKCE, client, redirect, and resource values" do
    user = user_fixture()
    client = oauth_client_fixture()
    verifier = String.duplicate("a", 64)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    request = %{
      client_id: client.client_id,
      client_name: client.client_name,
      redirect_uri: hd(client.redirect_uris),
      code_challenge: challenge,
      scope: OAuth.scope(),
      resource: OAuth.resource(),
      state: nil
    }

    {:ok, code} = OAuth.authorize(Scope.for_user(user), request)

    assert {:error, :invalid_grant} =
             OAuth.exchange_authorization_code(%{
               "code" => code,
               "client_id" => client.client_id,
               "redirect_uri" => request.redirect_uri,
               "code_verifier" => String.duplicate("b", 64),
               "resource" => OAuth.resource()
             })

    {:ok, code} = OAuth.authorize(Scope.for_user(user), request)

    assert {:ok, credentials} =
             OAuth.exchange_authorization_code(%{
               "code" => code,
               "client_id" => client.client_id,
               "redirect_uri" => request.redirect_uri,
               "code_verifier" => verifier,
               "resource" => OAuth.resource()
             })

    assert {:ok, %{current_scope: %{user: %{id: user_id}}}} =
             OAuth.authenticate_access_token(credentials["access_token"])

    assert user_id == user.id

    assert {:error, :invalid_grant} =
             OAuth.exchange_authorization_code(%{
               "code" => code,
               "client_id" => client.client_id,
               "redirect_uri" => request.redirect_uri,
               "code_verifier" => verifier,
               "resource" => OAuth.resource()
             })
  end

  test "expired codes and credentials are rejected and cleaned up" do
    user = user_fixture()
    client = oauth_client_fixture()
    verifier = String.duplicate("e", 64)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    request = %{
      client_id: client.client_id,
      client_name: client.client_name,
      redirect_uri: hd(client.redirect_uris),
      code_challenge: challenge,
      scope: OAuth.scope(),
      resource: OAuth.resource(),
      state: nil
    }

    {:ok, code} = OAuth.authorize(Scope.for_user(user), request)
    code_hash = :crypto.hash(:sha256, code)

    AuthorizationCode
    |> where([c], c.token_hash == ^code_hash)
    |> Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])

    assert {:error, :invalid_grant} =
             OAuth.exchange_authorization_code(%{
               "code" => code,
               "client_id" => client.client_id,
               "redirect_uri" => request.redirect_uri,
               "code_verifier" => verifier,
               "resource" => OAuth.resource()
             })

    %{credentials: credentials, client: issued_client} = oauth_credentials_fixture(user)
    access_hash = :crypto.hash(:sha256, credentials["access_token"])
    refresh_hash = :crypto.hash(:sha256, credentials["refresh_token"])
    expired_at = DateTime.add(DateTime.utc_now(), -1, :second)

    Token
    |> where([t], t.access_token_hash == ^access_hash and t.refresh_token_hash == ^refresh_hash)
    |> Repo.update_all(set: [access_expires_at: expired_at, refresh_expires_at: expired_at])

    assert {:error, :invalid_token} = OAuth.authenticate_access_token(credentials["access_token"])

    assert {:error, :invalid_grant} =
             OAuth.refresh(%{
               "refresh_token" => credentials["refresh_token"],
               "client_id" => issued_client.client_id,
               "resource" => OAuth.resource()
             })

    assert {count, nil} = OAuth.delete_expired_credentials()
    assert count >= 2
  end

  test "refresh tokens rotate and replay revokes the grant" do
    user = user_fixture()
    %{client: client, credentials: credentials} = oauth_credentials_fixture(user)

    params = %{
      "refresh_token" => credentials["refresh_token"],
      "client_id" => client.client_id,
      "resource" => OAuth.resource()
    }

    assert {:ok, rotated} = OAuth.refresh(params)
    refute rotated["refresh_token"] == credentials["refresh_token"]

    assert {:error, :invalid_grant} = OAuth.refresh(params)
    assert {:error, :invalid_token} = OAuth.authenticate_access_token(rotated["access_token"])
  end

  test "reauthorizing the same client invalidates its previous credentials" do
    user = user_fixture()
    %{request: request, credentials: credentials} = oauth_credentials_fixture(user)

    assert {:ok, _new_code} = OAuth.authorize(Scope.for_user(user), request)
    assert {:error, :invalid_token} = OAuth.authenticate_access_token(credentials["access_token"])
  end

  test "a user can list and revoke only their own grants" do
    user = user_fixture()
    other_user = user_fixture()
    %{credentials: credentials} = oauth_credentials_fixture(user)

    [grant] = OAuth.list_grants(Scope.for_user(user))
    assert OAuth.list_grants(Scope.for_user(other_user)) == []
    assert {:error, :not_found} = OAuth.revoke_grant(Scope.for_user(other_user), grant.id)
    assert :ok = OAuth.revoke_grant(Scope.for_user(user), grant.id)
    assert {:error, :invalid_token} = OAuth.authenticate_access_token(credentials["access_token"])
  end

  test "changing a password revokes OAuth grants" do
    user = user_fixture()
    %{credentials: credentials} = oauth_credentials_fixture(user)
    password = "an entirely new password"

    assert {:ok, {_user, _sessions}} =
             WhisperLogs.Accounts.update_user_password(user, %{
               password: password,
               password_confirmation: password
             })

    assert {:error, :invalid_token} = OAuth.authenticate_access_token(credentials["access_token"])
  end
end
