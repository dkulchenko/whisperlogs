defmodule WhisperLogs.OAuth do
  @moduledoc """
  OAuth 2.1 authorization for the WhisperLogs MCP resource.

  Authorization codes and bearer credentials are opaque. Only SHA-256 hashes are stored.
  """

  import Ecto.Query, warn: false

  alias WhisperLogs.Accounts.{Scope, User}
  alias WhisperLogs.OAuth.{AuthorizationCode, Grant, Token}
  alias WhisperLogs.Repo

  @scope "logs:read"
  @authorization_request_salt "oauth-authorization-request-v1"
  @code_lifetime_seconds 300
  @access_lifetime_seconds 3_600
  @refresh_lifetime_seconds 30 * 86_400
  @authorization_request_lifetime_seconds 600

  def scope, do: @scope

  def issuer do
    WhisperLogsWeb.Endpoint.url()
    |> String.trim_trailing("/")
  end

  def resource do
    issuer() <> "/mcp"
  end

  def sign_authorization_request(request) when is_map(request) do
    Phoenix.Token.encrypt(
      WhisperLogsWeb.Endpoint,
      @authorization_request_salt,
      request,
      max_age: @authorization_request_lifetime_seconds
    )
  end

  def verify_authorization_request(token) when is_binary(token) do
    Phoenix.Token.decrypt(
      WhisperLogsWeb.Endpoint,
      @authorization_request_salt,
      token,
      max_age: @authorization_request_lifetime_seconds
    )
  end

  def verify_authorization_request(_token), do: {:error, :missing}

  def authorize(%Scope{user: %User{} = user}, request) when is_map(request) do
    now = DateTime.utc_now(:microsecond)
    client_key_hash = client_key_hash(request.client_id, request.redirect_uri)

    Repo.transaction(fn ->
      grant =
        Grant
        |> where(
          [g],
          g.user_id == ^user.id and g.client_key_hash == ^client_key_hash and
            g.client_id == ^request.client_id and g.redirect_uri == ^request.redirect_uri
        )
        |> Repo.one()
        |> upsert_grant(user, request, client_key_hash, now)

      revoke_credentials(grant.id, now)

      {raw_code, token_hash} = new_credential()

      %AuthorizationCode{
        grant_id: grant.id,
        token_hash: token_hash,
        redirect_uri: request.redirect_uri,
        code_challenge: request.code_challenge,
        expires_at: DateTime.add(now, @code_lifetime_seconds, :second)
      }
      |> Repo.insert!()

      raw_code
    end)
  end

  def exchange_authorization_code(%{"code" => code} = params) when is_binary(code) do
    now = DateTime.utc_now(:microsecond)
    code_hash = hash(code)

    Repo.transaction(fn ->
      code =
        AuthorizationCode
        |> where([c], c.token_hash == ^code_hash)
        |> preload(grant: :user)
        |> Repo.one()

      with %AuthorizationCode{} <- code,
           :ok <- valid_code_exchange(code, params, now),
           {1, _} <-
             AuthorizationCode
             |> where([c], c.id == ^code.id and is_nil(c.used_at) and c.expires_at > ^now)
             |> Repo.update_all(set: [used_at: now]),
           {:ok, credentials} <- issue_tokens(code.grant, now) do
        credentials
      else
        _ -> Repo.rollback(:invalid_grant)
      end
    end)
    |> unwrap_transaction()
  end

  def exchange_authorization_code(_params), do: {:error, :invalid_grant}

  def refresh(%{"refresh_token" => refresh_token} = params) when is_binary(refresh_token) do
    now = DateTime.utc_now(:microsecond)
    refresh_hash = hash(refresh_token)

    Repo.transaction(fn ->
      token =
        Token
        |> where([t], t.refresh_token_hash == ^refresh_hash)
        |> preload(grant: :user)
        |> Repo.one()

      case token do
        %Token{refresh_used_at: used_at} when not is_nil(used_at) ->
          revoke_grant_by_id(token.grant_id, now)
          {:replay, :invalid_grant}

        %Token{} ->
          with :ok <- valid_refresh(token, params, now) do
            claimed =
              Token
              |> where(
                [t],
                t.id == ^token.id and is_nil(t.refresh_used_at) and is_nil(t.revoked_at)
              )
              |> Repo.update_all(set: [refresh_used_at: now, revoked_at: now])

            case claimed do
              {1, _} ->
                case issue_tokens(token.grant, now) do
                  {:ok, credentials} -> credentials
                  {:error, reason} -> Repo.rollback(reason)
                end

              {0, _} ->
                revoke_grant_by_id(token.grant_id, now)
                {:replay, :invalid_grant}
            end
          else
            _ -> Repo.rollback(:invalid_grant)
          end

        nil ->
          Repo.rollback(:invalid_grant)
      end
    end)
    |> unwrap_transaction()
  end

  def refresh(_params), do: {:error, :invalid_grant}

  def authenticate_access_token(raw_token)
      when is_binary(raw_token) and raw_token != "" and byte_size(raw_token) <= 512 do
    now = DateTime.utc_now(:microsecond)
    access_hash = hash(raw_token)

    token =
      Token
      |> join(:inner, [t], g in assoc(t, :grant))
      |> join(:inner, [_t, g], u in assoc(g, :user))
      |> where(
        [t, g, _u],
        t.access_token_hash == ^access_hash and is_nil(t.revoked_at) and
          t.access_expires_at > ^now and is_nil(g.revoked_at) and g.resource == ^resource() and
          g.scope == ^@scope
      )
      |> select([_t, g, u], {g, u})
      |> Repo.one()

    case token do
      {%Grant{} = grant, %User{} = user} ->
        {:ok, %{current_scope: Scope.for_user(user), grant: grant}}

      nil ->
        {:error, :invalid_token}
    end
  end

  def authenticate_access_token(_raw_token), do: {:error, :invalid_token}

  def list_grants(%Scope{user: %User{id: user_id}}) do
    Grant
    |> where([g], g.user_id == ^user_id and is_nil(g.revoked_at))
    |> order_by([g], desc: g.updated_at, desc: g.id)
    |> Repo.all()
  end

  def revoke_grant(%Scope{user: %User{id: user_id}}, grant_id) do
    now = DateTime.utc_now(:microsecond)

    {count, _} =
      Grant
      |> where([g], g.id == ^grant_id and g.user_id == ^user_id and is_nil(g.revoked_at))
      |> Repo.update_all(set: [revoked_at: now, updated_at: now])

    if count == 1 do
      Token
      |> where([t], t.grant_id == ^grant_id and is_nil(t.revoked_at))
      |> Repo.update_all(set: [revoked_at: now, updated_at: now])

      :ok
    else
      {:error, :not_found}
    end
  end

  def revoke_all_for_user(%User{id: user_id}) do
    now = DateTime.utc_now(:microsecond)

    grant_ids =
      Grant
      |> where([g], g.user_id == ^user_id and is_nil(g.revoked_at))
      |> select([g], g.id)
      |> Repo.all()

    Grant
    |> where([g], g.id in ^grant_ids)
    |> Repo.update_all(set: [revoked_at: now, updated_at: now])

    Token
    |> where([t], t.grant_id in ^grant_ids and is_nil(t.revoked_at))
    |> Repo.update_all(set: [revoked_at: now, updated_at: now])

    :ok
  end

  def delete_expired_credentials do
    now = DateTime.utc_now(:microsecond)
    revoked_cutoff = DateTime.add(now, -90, :day)

    {codes, _} =
      AuthorizationCode
      |> where([c], c.expires_at < ^now or not is_nil(c.used_at))
      |> Repo.delete_all()

    {tokens, _} =
      Token
      |> where([t], t.refresh_expires_at < ^now)
      |> Repo.delete_all()

    {grants, _} =
      Grant
      |> where([g], not is_nil(g.revoked_at) and g.revoked_at < ^revoked_cutoff)
      |> Repo.delete_all()

    {codes + tokens + grants, nil}
  end

  defp upsert_grant(nil, user, request, client_key_hash, _now) do
    %Grant{
      user_id: user.id,
      client_id: request.client_id,
      client_key_hash: client_key_hash,
      client_name: request.client_name,
      redirect_uri: request.redirect_uri,
      scope: @scope,
      resource: resource()
    }
    |> Repo.insert!()
  end

  defp upsert_grant(%Grant{} = grant, _user, request, _client_key_hash, now) do
    grant
    |> Ecto.Changeset.change(%{
      client_name: request.client_name,
      scope: @scope,
      resource: resource(),
      revoked_at: nil,
      updated_at: now
    })
    |> Repo.update!()
  end

  defp revoke_credentials(grant_id, now) do
    AuthorizationCode
    |> where([c], c.grant_id == ^grant_id)
    |> Repo.delete_all()

    Token
    |> where([t], t.grant_id == ^grant_id and is_nil(t.revoked_at))
    |> Repo.update_all(set: [revoked_at: now, updated_at: now])
  end

  defp valid_code_exchange(code, params, now) do
    grant = code.grant

    cond do
      not is_nil(code.used_at) or DateTime.compare(code.expires_at, now) != :gt ->
        {:error, :invalid_grant}

      not is_nil(grant.revoked_at) ->
        {:error, :invalid_grant}

      params["client_id"] != grant.client_id or params["redirect_uri"] != code.redirect_uri ->
        {:error, :invalid_grant}

      params["resource"] != grant.resource ->
        {:error, :invalid_target}

      not valid_code_verifier?(params["code_verifier"], code.code_challenge) ->
        {:error, :invalid_grant}

      true ->
        :ok
    end
  end

  defp valid_refresh(token, params, now) do
    grant = token.grant
    requested_scope = Map.get(params, "scope", grant.scope)

    cond do
      not is_nil(token.revoked_at) or DateTime.compare(token.refresh_expires_at, now) != :gt ->
        {:error, :invalid_grant}

      not is_nil(grant.revoked_at) ->
        {:error, :invalid_grant}

      params["client_id"] != grant.client_id ->
        {:error, :invalid_client}

      params["resource"] != grant.resource ->
        {:error, :invalid_target}

      requested_scope != grant.scope ->
        {:error, :invalid_scope}

      true ->
        :ok
    end
  end

  defp valid_code_verifier?(verifier, challenge)
       when is_binary(verifier) and byte_size(verifier) in 43..128 do
    calculated = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    byte_size(calculated) == byte_size(challenge) and
      Plug.Crypto.secure_compare(calculated, challenge)
  end

  defp valid_code_verifier?(_verifier, _challenge), do: false

  defp issue_tokens(grant, now) do
    {access_token, access_hash} = new_credential()
    {refresh_token, refresh_hash} = new_credential()

    %Token{
      grant_id: grant.id,
      access_token_hash: access_hash,
      refresh_token_hash: refresh_hash,
      access_expires_at: DateTime.add(now, @access_lifetime_seconds, :second),
      refresh_expires_at: DateTime.add(now, @refresh_lifetime_seconds, :second)
    }
    |> Repo.insert()
    |> case do
      {:ok, _token} ->
        {:ok,
         %{
           "access_token" => access_token,
           "token_type" => "Bearer",
           "expires_in" => @access_lifetime_seconds,
           "refresh_token" => refresh_token,
           "scope" => grant.scope
         }}

      {:error, _changeset} ->
        {:error, :server_error}
    end
  end

  defp revoke_grant_by_id(grant_id, now) do
    Grant
    |> where([g], g.id == ^grant_id)
    |> Repo.update_all(set: [revoked_at: now, updated_at: now])

    Token
    |> where([t], t.grant_id == ^grant_id and is_nil(t.revoked_at))
    |> Repo.update_all(set: [revoked_at: now, updated_at: now])
  end

  defp new_credential do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    {raw, hash(raw)}
  end

  defp hash(value) when is_binary(value), do: :crypto.hash(:sha256, value)

  defp client_key_hash(client_id, redirect_uri), do: hash(client_id <> <<0>> <> redirect_uri)

  defp unwrap_transaction({:ok, {:replay, reason}}), do: {:error, reason}
  defp unwrap_transaction({:ok, credentials}), do: {:ok, credentials}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
