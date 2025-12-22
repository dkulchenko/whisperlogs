defmodule WhisperLogsWeb.LogController do
  use WhisperLogsWeb, :controller

  alias WhisperLogs.Logs

  @doc """
  Ingests log entries.

  POST /api/v1/logs
  {
    "logs": [
      {
        "timestamp": "2024-01-15T10:30:00.123456Z",
        "level": "info",
        "message": "User signed in",
        "metadata": {"user_id": 123},
        "request_id": "abc123"
      }
    ]
  }

  The source is taken from the API key, not the payload.
  """
  def ingest(conn, %{"logs" => logs}) when is_list(logs) do
    source = conn.assigns.source

    {count, _} = Logs.insert_batch(source, logs)

    conn
    |> put_status(:ok)
    |> json(%{ok: true, count: count})
  end

  def ingest(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing 'logs' array in request body"})
  end
end
