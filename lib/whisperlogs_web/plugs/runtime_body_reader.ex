defmodule WhisperLogsWeb.Plugs.RuntimeBodyReader do
  @moduledoc false

  import Plug.Conn

  def read_body(conn, opts) do
    with :ok <- validate_content_encoding(conn) do
      max_bytes = WhisperLogs.Config.receiver_limits().max_request_bytes

      opts =
        opts
        |> Keyword.put(:length, max_bytes + 1)
        |> Keyword.put(:read_length, min(max_bytes + 1, 1_000_000))

      conn
      |> Plug.Conn.read_body(opts)
      |> enforce_running_limit(max_bytes)
    end
  end

  defp enforce_running_limit({status, body, conn}, max_bytes) when status in [:ok, :more] do
    total = Map.get(conn.private, :whisperlogs_body_bytes, 0) + byte_size(body)
    conn = put_private(conn, :whisperlogs_body_bytes, total)

    # Plug.Parsers maps `:more` to its stable RequestTooLargeError/413 path.
    if total > max_bytes, do: {:more, "", conn}, else: {status, body, conn}
  end

  defp enforce_running_limit(result, _max_bytes), do: result

  defp validate_content_encoding(conn) do
    case get_req_header(conn, "content-encoding") do
      [] -> :ok
      [encoding] when encoding in ["identity", ""] -> :ok
      _other -> {:error, :unsupported_content_encoding}
    end
  end
end
