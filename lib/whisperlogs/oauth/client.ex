defmodule WhisperLogs.OAuth.Client do
  @moduledoc """
  Resolves OAuth public clients from CIMD documents or stateless DCR client IDs.
  """

  @dcr_prefix "wl_dcr_"
  @dcr_salt "oauth-dcr-client-v1"
  @max_document_bytes 65_536
  @max_client_id_bytes 4_096
  @max_redirect_uri_bytes 2_048
  @loopback_hosts ["localhost", "127.0.0.1", "::1"]

  @type t :: %{
          client_id: String.t(),
          client_name: String.t(),
          redirect_uris: [String.t()]
        }

  def register(metadata) when is_map(metadata) do
    with {:ok, normalized} <- validate_metadata(metadata, nil) do
      payload = Map.take(normalized, [:client_name, :redirect_uris])

      client_id =
        @dcr_prefix <>
          Phoenix.Token.sign(WhisperLogsWeb.Endpoint, @dcr_salt, payload, max_age: :infinity)

      {:ok, Map.put(normalized, :client_id, client_id)}
    end
  end

  def resolve(@dcr_prefix <> token = client_id) do
    with {:ok, metadata} <-
           Phoenix.Token.verify(WhisperLogsWeb.Endpoint, @dcr_salt, token, max_age: :infinity),
         {:ok, normalized} <- validate_metadata(metadata, client_id) do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_client}
    end
  end

  def resolve(client_id)
      when is_binary(client_id) and byte_size(client_id) <= @max_client_id_bytes do
    with {:ok, uri} <- validate_cimd_uri(client_id),
         {:ok, address} <- public_destination(uri),
         {:ok, response} <- fetch_document(uri, address),
         :ok <- validate_response(response),
         {:ok, metadata} <- decode_document(response.body),
         {:ok, normalized} <- validate_metadata(metadata, client_id) do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_client}
    end
  end

  def resolve(_client_id), do: {:error, :invalid_client}

  def valid_redirect_uri?(redirect_uri) when is_binary(redirect_uri) do
    byte_size(redirect_uri) <= @max_redirect_uri_bytes and
      case URI.new(redirect_uri) do
        {:ok, %URI{scheme: "https", host: host, port: port, userinfo: nil, fragment: nil}}
        when is_binary(host) and host != "" and port in 1..65_535 ->
          true

        {:ok, %URI{scheme: "http", host: host, port: port, userinfo: nil, fragment: nil}}
        when host in @loopback_hosts and port in 1..65_535 ->
          true

        _ ->
          false
      end
  end

  def valid_redirect_uri?(_redirect_uri), do: false

  def redirect_uri_allowed?(%{redirect_uris: redirect_uris}, redirect_uri)
      when is_list(redirect_uris) and is_binary(redirect_uri) do
    redirect_uri in redirect_uris or
      (valid_redirect_uri?(redirect_uri) and
         Enum.any?(redirect_uris, &loopback_redirect_uri_match?(&1, redirect_uri)))
  end

  def redirect_uri_allowed?(_client, _redirect_uri), do: false

  defp validate_cimd_uri(client_id) do
    case URI.parse(client_id) do
      %URI{scheme: "https", host: host, path: path, userinfo: nil, fragment: nil} = uri
      when is_binary(host) and host != "" and is_binary(path) and path not in ["", "/"] ->
        {:ok, uri}

      _ ->
        {:error, :invalid_client_id_uri}
    end
  end

  defp loopback_redirect_uri_match?(registered_redirect_uri, requested_redirect_uri) do
    with {:ok, registered} <- URI.new(registered_redirect_uri),
         {:ok, requested} <- URI.new(requested_redirect_uri) do
      registered.scheme == "http" and
        requested.scheme == registered.scheme and
        registered.host in @loopback_hosts and
        requested.host == registered.host and
        requested.userinfo == registered.userinfo and
        requested.path == registered.path and
        requested.query == registered.query and
        requested.fragment == registered.fragment
    else
      _ -> false
    end
  end

  defp fetch_document(%URI{host: hostname} = uri, address) do
    pinned_url = URI.to_string(%{uri | host: address |> :inet.ntoa() |> to_string()})

    Req.get(pinned_url,
      redirect: false,
      retry: false,
      receive_timeout: 3_000,
      decode_body: false,
      connect_options: [hostname: hostname, timeout: 3_000],
      headers: [{"accept", "application/json"}],
      into: &collect_bounded_body/2
    )
  rescue
    _ -> {:error, :fetch_failed}
  end

  defp collect_bounded_body({:data, data}, {request, response}) do
    if byte_size(response.body) + byte_size(data) <= @max_document_bytes do
      {:cont, {request, %{response | body: response.body <> data}}}
    else
      response =
        %{response | private: Map.put(response.private, :whisperlogs_body_too_large, true)}

      {:halt, {request, response}}
    end
  end

  defp validate_response(%Req.Response{
         status: 200,
         body: body,
         headers: headers,
         private: private
       })
       when is_binary(body) and byte_size(body) <= @max_document_bytes do
    content_type = headers |> Map.get("content-type", []) |> List.first()

    if not Map.get(private, :whisperlogs_body_too_large, false) and
         json_content_type?(content_type) do
      :ok
    else
      {:error, :invalid_content_type}
    end
  end

  defp validate_response(_response), do: {:error, :invalid_response}

  defp json_content_type?(content_type) when is_binary(content_type) do
    media_type =
      content_type
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    media_type == "application/json"
  end

  defp json_content_type?(_content_type), do: false

  defp decode_document(body) do
    case Jason.decode(body) do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      _ -> {:error, :invalid_document}
    end
  end

  defp validate_metadata(metadata, expected_client_id) do
    client_id = value(metadata, :client_id) || expected_client_id
    supplied_client_name = value(metadata, :client_name)
    client_name = supplied_client_name || "OAuth client"
    redirect_uris = value(metadata, :redirect_uris)
    grant_types = value(metadata, :grant_types, ["authorization_code", "refresh_token"])
    response_types = value(metadata, :response_types, ["code"])
    auth_method = value(metadata, :token_endpoint_auth_method, "none")

    cond do
      not is_nil(expected_client_id) and client_id != expected_client_id ->
        {:error, :client_id_mismatch}

      not is_nil(expected_client_id) and is_nil(supplied_client_name) ->
        {:error, :missing_client_name}

      not is_binary(client_name) or client_name == "" or byte_size(client_name) > 100 ->
        {:error, :invalid_client_name}

      not is_list(redirect_uris) or redirect_uris == [] or
          not Enum.all?(redirect_uris, &valid_redirect_uri?/1) ->
        {:error, :invalid_redirect_uris}

      length(redirect_uris) > 10 or length(Enum.uniq(redirect_uris)) != length(redirect_uris) ->
        {:error, :invalid_redirect_uris}

      auth_method != "none" ->
        {:error, :unsupported_auth_method}

      not is_list(grant_types) or not Enum.all?(grant_types, &is_binary/1) ->
        {:error, :invalid_grant_types}

      not is_list(response_types) or not Enum.all?(response_types, &is_binary/1) ->
        {:error, :invalid_response_types}

      "authorization_code" not in grant_types or "code" not in response_types ->
        {:error, :unsupported_client}

      true ->
        {:ok,
         %{
           client_id: client_id,
           client_name: client_name,
           redirect_uris: redirect_uris
         }}
    end
  end

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp public_destination(%URI{host: host}) do
    host = String.trim(host, "[]")

    addresses =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, address} -> [address]
        {:error, :einval} -> resolve_addresses(host)
      end

    if addresses != [] and Enum.all?(addresses, &public_address?/1) do
      {:ok, hd(addresses)}
    else
      {:error, :unsafe_destination}
    end
  end

  defp resolve_addresses(host) do
    host = String.to_charlist(host)

    [:inet, :inet6]
    |> Enum.flat_map(fn family ->
      case :inet.getaddrs(host, family) do
        {:ok, addresses} -> addresses
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq()
  end

  defp public_address?({a, b, _c, _d}) do
    cond do
      a in [0, 10, 127] -> false
      a == 100 and b in 64..127 -> false
      a == 169 and b == 254 -> false
      a == 172 and b in 16..31 -> false
      a == 192 and b == 168 -> false
      a == 198 and b in [18, 19] -> false
      a >= 224 -> false
      true -> true
    end
  end

  defp public_address?({a, _b, _c, _d, _e, _f, _g, _h}) do
    cond do
      a == 0 -> false
      Bitwise.band(a, 0xFFC0) == 0xFE80 -> false
      Bitwise.band(a, 0xFFC0) == 0xFEC0 -> false
      Bitwise.band(a, 0xFE00) == 0xFC00 -> false
      Bitwise.band(a, 0xFF00) == 0xFF00 -> false
      true -> true
    end
  end
end
