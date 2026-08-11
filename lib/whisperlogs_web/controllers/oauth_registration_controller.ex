defmodule WhisperLogsWeb.OAuthRegistrationController do
  use WhisperLogsWeb, :controller

  alias WhisperLogs.OAuth.Client

  def create(conn, params) do
    case Client.register(params) do
      {:ok, client} ->
        conn
        |> put_status(:created)
        |> no_store()
        |> json(%{
          "client_id" => client.client_id,
          "client_name" => client.client_name,
          "redirect_uris" => client.redirect_uris,
          "grant_types" => ["authorization_code", "refresh_token"],
          "response_types" => ["code"],
          "token_endpoint_auth_method" => "none"
        })

      {:error, _reason} ->
        conn
        |> put_status(:bad_request)
        |> no_store()
        |> json(%{
          "error" => "invalid_client_metadata",
          "error_description" => "The public client metadata is invalid."
        })
    end
  end

  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
