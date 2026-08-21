defmodule WhisperLogsWeb.OAuthAuthorizationController do
  use WhisperLogsWeb, :controller

  alias WhisperLogs.OAuth
  alias WhisperLogs.OAuth.Client

  def new(conn, params) do
    with {:ok, request} <- validate_request(params),
         authorization_request <- OAuth.sign_authorization_request(request) do
      conn
      |> no_store()
      |> render(:consent,
        current_scope: conn.assigns.current_scope,
        client: request,
        form: Phoenix.Component.to_form(%{}),
        authorization_request: authorization_request
      )
    else
      {:error, reason} -> invalid_request(conn, reason)
    end
  end

  def create(conn, %{"authorization_request" => token, "decision" => decision})
      when decision in ["allow", "deny"] do
    with {:ok, request} <- OAuth.verify_authorization_request(token) do
      if decision == "allow" do
        {:ok, code} = OAuth.authorize(conn.assigns.current_scope, request)

        redirect_external(no_store(conn), request.redirect_uri, %{
          "code" => code,
          "state" => request.state,
          "iss" => OAuth.issuer()
        })
      else
        redirect_external(no_store(conn), request.redirect_uri, %{
          "error" => "access_denied",
          "state" => request.state,
          "iss" => OAuth.issuer()
        })
      end
    else
      _ -> invalid_request(conn, :expired_request)
    end
  end

  def create(conn, _params), do: invalid_request(conn, :invalid_request)

  defp validate_request(params) do
    with {:ok, response_type} <- required(params, "response_type"),
         true <- response_type == "code",
         {:ok, client_id} <- required(params, "client_id"),
         {:ok, redirect_uri} <- required(params, "redirect_uri"),
         {:ok, code_challenge} <- required(params, "code_challenge"),
         {:ok, code_challenge_method} <- required(params, "code_challenge_method"),
         true <- code_challenge_method == "S256",
         true <- valid_code_challenge?(code_challenge),
         {:ok, scope} <- required(params, "scope"),
         true <- scope == OAuth.scope(),
         {:ok, resource} <- required(params, "resource"),
         true <- resource == OAuth.resource(),
         {:ok, client} <- Client.resolve(client_id),
         true <- Client.redirect_uri_allowed?(client, redirect_uri),
         {:ok, state} <- optional_state(params) do
      {:ok,
       %{
         client_id: client.client_id,
         client_name: client.client_name,
         redirect_uri: redirect_uri,
         code_challenge: code_challenge,
         scope: scope,
         resource: resource,
         state: state
       }}
    else
      _ -> {:error, :invalid_authorization_request}
    end
  end

  defp required(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_parameter}
    end
  end

  defp optional_state(params) do
    case Map.get(params, "state") do
      nil -> {:ok, nil}
      state when is_binary(state) and byte_size(state) <= 2_048 -> {:ok, state}
      _ -> {:error, :invalid_state}
    end
  end

  defp valid_code_challenge?(challenge) do
    byte_size(challenge) == 43 and Regex.match?(~r/^[A-Za-z0-9_-]+$/, challenge)
  end

  defp invalid_request(conn, _reason) do
    conn
    |> put_status(:bad_request)
    |> no_store()
    |> render(:invalid_request, current_scope: conn.assigns.current_scope)
  end

  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  defp redirect_external(conn, redirect_uri, params) do
    encoded =
      params
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> URI.encode_query()

    uri = URI.parse(redirect_uri)
    query = Enum.reject([uri.query, encoded], &(&1 in [nil, ""])) |> Enum.join("&")
    external = URI.to_string(%{uri | query: query})

    redirect(conn, external: external)
  end
end
