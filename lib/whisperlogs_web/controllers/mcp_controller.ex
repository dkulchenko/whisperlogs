defmodule WhisperLogsWeb.McpController do
  use WhisperLogsWeb, :controller

  alias WhisperLogs.{MCP, OAuth}

  def handle(conn, body) do
    with :ok <- validate_origin(conn),
         {:ok, auth} <- authenticate(conn),
         :ok <- validate_accept(conn),
         :ok <- validate_content_type(conn),
         :ok <- validate_request_shape(body),
         :ok <- validate_protocol(conn, body),
         :ok <- validate_mirrored_headers(conn, body) do
      dispatch(conn, body, auth)
    else
      {:error, :invalid_origin} ->
        rpc_error(conn, nil, 403, -32_000, "Invalid Origin")

      {:error, :unauthorized} ->
        unauthorized(conn)

      {:error, :invalid_accept} ->
        rpc_error(conn, request_id(body), 406, -32_600, "Not acceptable")

      {:error, :invalid_content_type} ->
        rpc_error(conn, request_id(body), 415, -32_600, "Content-Type must be application/json")

      {:error, :invalid_request} ->
        rpc_error(conn, request_id(body), 400, -32_600, "Invalid Request")

      {:error, :header_mismatch, message} ->
        rpc_error(conn, request_id(body), 400, -32_020, message)

      {:error, :unsupported_version} ->
        unsupported_version(conn, request_id(body))
    end
  end

  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> rpc_error(nil, 405, -32_601, "Method not found")
  end

  defp dispatch(conn, %{"id" => id, "method" => "server/discover"}, _auth) do
    rpc_result(conn, id, MCP.discover_result())
  end

  defp dispatch(conn, %{"id" => id, "method" => "tools/list"}, _auth) do
    rpc_result(conn, id, MCP.tools_result())
  end

  defp dispatch(
         conn,
         %{"id" => id, "method" => "tools/call", "params" => params},
         %{current_scope: scope}
       ) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    case MCP.call(scope, name, arguments) do
      {:ok, result} -> rpc_result(conn, id, result)
      {:error, :unknown_tool} -> rpc_error(conn, id, 200, -32_602, "Unknown tool")
    end
  end

  defp dispatch(conn, %{"id" => id}, _auth) do
    rpc_error(conn, id, 404, -32_601, "Method not found")
  end

  defp validate_request_shape(%{
         "jsonrpc" => "2.0",
         "id" => id,
         "method" => method,
         "params" => params
       })
       when not is_nil(id) and is_binary(method) and is_map(params),
       do: :ok

  defp validate_request_shape(_body), do: {:error, :invalid_request}

  defp validate_protocol(conn, body) do
    header_version = single_header(conn, "mcp-protocol-version")
    meta_version = get_in(body, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"])
    client_info = get_in(body, ["params", "_meta", "io.modelcontextprotocol/clientInfo"])

    client_capabilities =
      get_in(body, ["params", "_meta", "io.modelcontextprotocol/clientCapabilities"])

    cond do
      not valid_client_info?(client_info) or not is_map(client_capabilities) ->
        {:error, :invalid_request}

      not is_binary(header_version) or header_version != meta_version ->
        {:error, :header_mismatch, "MCP-Protocol-Version does not match request metadata"}

      header_version != MCP.protocol_version() ->
        {:error, :unsupported_version}

      true ->
        :ok
    end
  end

  defp valid_client_info?(%{"name" => name, "version" => version})
       when is_binary(name) and name != "" and is_binary(version) and version != "",
       do: true

  defp valid_client_info?(_client_info), do: false

  defp validate_mirrored_headers(conn, body) do
    method = Map.get(body, "method")
    method_header = single_header(conn, "mcp-method")

    cond do
      method_header != method ->
        {:error, :header_mismatch, "Mcp-Method does not match the JSON-RPC method"}

      method == "tools/call" ->
        validate_name_header(conn, get_in(body, ["params", "name"]))

      true ->
        :ok
    end
  end

  defp validate_name_header(conn, name) when is_binary(name) do
    case single_header(conn, "mcp-name") |> decode_header_value() do
      {:ok, ^name} -> :ok
      _ -> {:error, :header_mismatch, "Mcp-Name does not match the requested tool"}
    end
  end

  defp validate_name_header(_conn, _name) do
    {:error, :header_mismatch, "Mcp-Name or tool name is missing"}
  end

  defp decode_header_value("=?base64?" <> encoded) do
    if String.ends_with?(encoded, "?=") do
      encoded = String.slice(encoded, 0, byte_size(encoded) - 2)

      case Base.decode64(encoded) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :invalid_encoding}
      end
    else
      {:error, :invalid_encoding}
    end
  end

  defp decode_header_value(value) when is_binary(value), do: {:ok, value}
  defp decode_header_value(_value), do: {:error, :missing}

  defp validate_accept(conn) do
    accept = conn |> get_req_header("accept") |> Enum.join(",")

    if String.contains?(accept, "application/json") and
         String.contains?(accept, "text/event-stream"),
       do: :ok,
       else: {:error, :invalid_accept}
  end

  defp validate_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [content_type] ->
        media_type =
          content_type
          |> String.split(";", parts: 2)
          |> hd()
          |> String.trim()
          |> String.downcase()

        if media_type == "application/json",
          do: :ok,
          else: {:error, :invalid_content_type}

      _ ->
        {:error, :invalid_content_type}
    end
  end

  defp validate_origin(conn) do
    issuer = OAuth.issuer()

    case get_req_header(conn, "origin") do
      [] -> :ok
      [^issuer] -> :ok
      _ -> {:error, :invalid_origin}
    end
  end

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case OAuth.authenticate_access_token(token) do
          {:ok, auth} -> {:ok, auth}
          {:error, _reason} -> {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp unauthorized(conn) do
    metadata_url = OAuth.issuer() <> "/.well-known/oauth-protected-resource"

    conn
    |> put_resp_header(
      "www-authenticate",
      ~s(Bearer resource_metadata="#{metadata_url}", scope="#{OAuth.scope()}")
    )
    |> put_resp_header("cache-control", "no-store")
    |> rpc_error(nil, 401, -32_000, "Unauthorized")
  end

  defp unsupported_version(conn, id) do
    conn
    |> put_status(:bad_request)
    |> put_resp_content_type("application/json")
    |> json(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32_022,
        "message" => "Unsupported protocol version",
        "data" => %{"supportedVersions" => [MCP.protocol_version()]}
      }
    })
  end

  defp rpc_result(conn, id, result) do
    conn
    |> put_resp_header("cache-control", "private, max-age=0")
    |> json(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp rpc_error(conn, id, status, code, message) do
    conn
    |> put_status(status)
    |> put_resp_content_type("application/json")
    |> json(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp request_id(body) when is_map(body), do: Map.get(body, "id")
  defp request_id(_body), do: nil

  defp single_header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _ -> nil
    end
  end
end
