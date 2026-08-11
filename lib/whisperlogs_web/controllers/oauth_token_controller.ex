defmodule WhisperLogsWeb.OAuthTokenController do
  use WhisperLogsWeb, :controller

  alias WhisperLogs.OAuth

  def create(conn, %{"grant_type" => "authorization_code"} = params) do
    token_response(conn, OAuth.exchange_authorization_code(params))
  end

  def create(conn, %{"grant_type" => "refresh_token"} = params) do
    token_response(conn, OAuth.refresh(params))
  end

  def create(conn, _params), do: oauth_error(conn, :unsupported_grant_type)

  defp token_response(conn, {:ok, credentials}) do
    conn
    |> no_store()
    |> json(credentials)
  end

  defp token_response(conn, {:error, reason}), do: oauth_error(conn, reason)

  defp oauth_error(conn, reason) do
    {error, description} =
      case reason do
        :invalid_target -> {"invalid_target", "The resource parameter is invalid."}
        :invalid_scope -> {"invalid_scope", "The requested scope is invalid."}
        :invalid_client -> {"invalid_client", "The public client is invalid."}
        :unsupported_grant_type -> {"unsupported_grant_type", "The grant type is unsupported."}
        _ -> {"invalid_grant", "The authorization grant is invalid or expired."}
      end

    conn
    |> put_status(:bad_request)
    |> no_store()
    |> json(%{"error" => error, "error_description" => description})
  end

  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
