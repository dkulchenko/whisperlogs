defmodule WhisperLogsWeb.Plugs.RuntimeRequestLimit do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    max_bytes = WhisperLogs.Config.receiver_limits().max_request_bytes

    case get_req_header(conn, "content-length") do
      [] -> conn
      [value] -> validate_length!(value, max_bytes, conn)
      _values -> raise Plug.BadRequestError, message: "multiple content-length headers"
    end
  end

  defp validate_length!(value, max_bytes, conn) do
    case Integer.parse(value) do
      {length, ""} when length >= 0 and length <= max_bytes -> conn
      {length, ""} when length > max_bytes -> raise Plug.Parsers.RequestTooLargeError
      _other -> raise Plug.BadRequestError, message: "invalid content-length header"
    end
  end
end
