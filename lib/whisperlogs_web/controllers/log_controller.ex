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
  def ingest(conn, params) when is_map(params) do
    source = conn.assigns.source
    logs = Map.get(params, "logs", :missing)

    case Logs.insert_batch(source, logs) do
      {:ok, inserted} ->
        conn
        |> put_status(:ok)
        |> json(%{ok: true, count: length(inserted)})

      {:error, %{field: :logs, reason: reason} = error} when reason in [:empty, :too_many] ->
        conn |> put_status(:request_entity_too_large) |> json(%{error: error})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: error})
    end
  end

  def ingest(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{field: :logs, reason: :invalid_batch}})
  end
end
