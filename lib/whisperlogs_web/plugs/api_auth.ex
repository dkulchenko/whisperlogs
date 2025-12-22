defmodule WhisperLogsWeb.Plugs.ApiAuth do
  @moduledoc """
  Plug that authenticates API requests using Bearer token authentication.

  Expects: `Authorization: Bearer wl_xxxxx...`

  On success, assigns `:api_key` to conn with the validated API key struct.
  On failure, returns 401 Unauthorized.
  """

  import Plug.Conn
  alias WhisperLogs.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, api_key} <- Accounts.get_api_key_by_token(token) do
      # Update last_used_at asynchronously (don't block the request)
      Task.start(fn -> Accounts.touch_api_key(api_key) end)

      conn
      |> assign(:api_key, api_key)
      |> assign(:source, api_key.source)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "Invalid or missing API key"})
        |> halt()
    end
  end
end
