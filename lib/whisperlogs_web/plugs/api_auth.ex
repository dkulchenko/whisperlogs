defmodule WhisperLogsWeb.Plugs.ApiAuth do
  @moduledoc """
  Plug that authenticates API requests using Bearer token authentication.

  Expects: `Authorization: Bearer wl_xxxxx...`

  On success, assigns `:http_source` to conn with the validated source struct.
  On failure, returns 401 Unauthorized.
  """

  import Plug.Conn
  alias WhisperLogs.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, http_source} <- Accounts.get_source_by_token(token) do
      # Update last_used_at asynchronously (don't block the request)
      Task.start(fn -> Accounts.touch_source(http_source) end)

      conn
      |> assign(:http_source, http_source)
      |> assign(:source, http_source.source)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "Invalid or missing API key"})
        |> halt()
    end
  end
end
