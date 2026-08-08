defmodule WhisperLogs.Exports.S3Client do
  @moduledoc "Bounded S3-compatible SigV4 client with exact-host multipart uploads."

  @part_bytes 8 * 1024 * 1024
  @xml_limit 1_048_576
  @bucket ~r/^[a-z0-9](?:[a-z0-9.-]{1,61}[a-z0-9])$/

  def valid_bucket?(bucket) when is_binary(bucket) do
    Regex.match?(@bucket, bucket) and
      not String.contains?(bucket, ["..", ".-", "-."]) and
      not ip_literal?(bucket)
  end

  def valid_bucket?(_), do: false

  def validate_destination(config) do
    endpoint = config.s3_endpoint
    bucket = config.s3_bucket

    cond do
      endpoint not in WhisperLogs.Config.s3_allowed_hosts() -> {:error, :endpoint_not_allowlisted}
      not valid_bucket?(bucket) -> {:error, :invalid_bucket}
      true -> validate_url(build_url(config, "", []), config)
    end
  end

  def test_connection(config) do
    with :ok <- validate_destination(config),
         {:ok, response} <- request(config, "HEAD", "", [], "", "", 10_000) do
      case response.status do
        status when status in 200..299 -> :ok
        301 -> {:error, :redirect_rejected}
        403 -> {:error, :access_denied}
        404 -> {:error, :bucket_not_found}
        status -> {:error, {:s3_status, status}}
      end
    end
  end

  def upload_file(config, key, path, deadline) do
    with :ok <- validate_destination(config),
         {:ok, upload_id} <- initiate(config, key, deadline) do
      case upload_parts(config, key, path, upload_id, deadline) do
        {:ok, parts} ->
          case complete(config, key, upload_id, parts, deadline) do
            :ok ->
              :ok

            {:error, _} = error ->
              abort(config, key, upload_id, deadline)
              error
          end

        {:error, _} = error ->
          abort(config, key, upload_id, deadline)
          error
      end
    end
  end

  def put_object(config, key, body, opts \\ []) when is_binary(body) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    with :ok <- validate_destination(config),
         {:ok, response} <- request(config, "PUT", key, [], body, content_type, 300_000) do
      if response.status in 200..299, do: :ok, else: {:error, {:s3_status, response.status}}
    end
  end

  defp initiate(config, key, deadline) do
    with {:ok, response} <-
           request(config, "POST", key, [{"uploads", ""}], "", "", remaining(deadline)),
         true <- response.status in 200..299 || {:error, {:s3_status, response.status}},
         {:ok, upload_id} <- xml_text(response.body, "UploadId") do
      if byte_size(upload_id) in 1..1024, do: {:ok, upload_id}, else: {:error, :invalid_upload_id}
    end
  end

  defp upload_parts(config, key, path, upload_id, deadline) do
    file = File.open!(path, [:read, :binary])

    try do
      Stream.repeatedly(fn -> IO.binread(file, @part_bytes) end)
      |> Stream.take_while(&(&1 != :eof))
      |> Enum.reduce_while({:ok, [], 1}, fn
        {:error, reason}, _acc ->
          {:halt, {:error, {:file_read, reason}}}

        body, {:ok, parts, number} ->
          query = [{"partNumber", Integer.to_string(number)}, {"uploadId", upload_id}]

          case request(
                 config,
                 "PUT",
                 key,
                 query,
                 body,
                 "application/octet-stream",
                 remaining(deadline)
               ) do
            {:ok, response} when response.status in 200..299 ->
              case Req.Response.get_header(response, "etag") do
                [etag | _] when byte_size(etag) <= 1024 ->
                  {:cont, {:ok, [{number, etag} | parts], number + 1}}

                _ ->
                  {:halt, {:error, :missing_etag}}
              end

            {:ok, response} ->
              {:halt, {:error, {:s3_status, response.status}}}

            {:error, _} = error ->
              {:halt, error}
          end
      end)
      |> case do
        {:ok, parts, _next} -> {:ok, Enum.reverse(parts)}
        error -> error
      end
    after
      File.close(file)
    end
  end

  defp complete(config, key, upload_id, parts, deadline) do
    body =
      [
        "<CompleteMultipartUpload>",
        Enum.map(parts, fn {number, etag} ->
          [
            "<Part><PartNumber>",
            Integer.to_string(number),
            "</PartNumber><ETag>",
            xml_escape(etag),
            "</ETag></Part>"
          ]
        end),
        "</CompleteMultipartUpload>"
      ]
      |> IO.iodata_to_binary()

    query = [{"uploadId", upload_id}]

    with {:ok, response} <-
           request(config, "POST", key, query, body, "application/xml", remaining(deadline)),
         true <- response.status in 200..299 || {:error, {:s3_status, response.status}} do
      if xml_element?(response.body, "Error"), do: {:error, :completion_error}, else: :ok
    end
  end

  defp abort(config, key, upload_id, deadline) do
    _ = request(config, "DELETE", key, [{"uploadId", upload_id}], "", "", remaining(deadline))
    :ok
  end

  defp request(config, method, key, query, body, content_type, timeout) when timeout > 0 do
    url = build_url(config, key, query)

    with :ok <- validate_url(url, config) do
      now = DateTime.utc_now()
      headers = signed_headers(config, method, key, query, body, content_type, now)

      options = [
        method: method,
        url: url,
        body: body,
        headers: headers,
        receive_timeout: timeout,
        request_timeout: timeout,
        finch: [pool_timeout: timeout],
        retry: false,
        redirect: false,
        raw: true,
        into: &collect_bounded_body/2
      ]

      case Req.request(options ++ Application.get_env(:whisperlogs, :s3_req_options, [])) do
        {:ok, %Req.Response{private: %{whisperlogs_body_too_large: true}}} ->
          {:error, :xml_response_too_large}

        result ->
          result
      end
    end
  end

  defp request(_config, _method, _key, _query, _body, _content_type, _timeout),
    do: {:error, :deadline_exceeded}

  defp collect_bounded_body({:data, data}, {request, response}) do
    body = response.body <> data

    if byte_size(body) > @xml_limit do
      response = %{
        response
        | body: "",
          private: Map.put(response.private, :whisperlogs_body_too_large, true)
      }

      {:halt, {request, response}}
    else
      {:cont, {request, %{response | body: body}}}
    end
  end

  defp build_url(config, key, query) do
    path = canonical_path(key)

    suffix =
      case canonical_query(query) do
        "" -> ""
        value -> "?" <> value
      end

    "https://#{config.s3_bucket}.#{config.s3_endpoint}#{path}#{suffix}"
  end

  defp validate_url(url, config) do
    expected = "#{config.s3_bucket}.#{config.s3_endpoint}"

    case URI.parse(url) do
      %URI{scheme: "https", host: ^expected, userinfo: nil, port: 443} -> :ok
      %URI{scheme: "https", host: ^expected, userinfo: nil, port: nil} -> :ok
      _ -> {:error, :invalid_final_authority}
    end
  end

  defp signed_headers(config, method, key, query, body, content_type, now) do
    date = Calendar.strftime(now, "%Y%m%d")
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    payload_hash = sha256(body)
    host = "#{config.s3_bucket}.#{config.s3_endpoint}"

    headers = [{"host", host}, {"x-amz-date", amz_date}, {"x-amz-content-sha256", payload_hash}]
    headers = if content_type == "", do: headers, else: [{"content-type", content_type} | headers]
    sorted = Enum.sort_by(headers, &elem(&1, 0))

    canonical_headers =
      Enum.map_join(sorted, "\n", fn {name, value} -> "#{name}:#{String.trim(value)}" end)

    names = Enum.map_join(sorted, ";", &elem(&1, 0))

    canonical =
      Enum.join(
        [
          method,
          canonical_path(key),
          canonical_query(query),
          canonical_headers,
          "",
          names,
          payload_hash
        ],
        "\n"
      )

    scope = "#{date}/#{config.s3_region}/s3/aws4_request"
    string = Enum.join(["AWS4-HMAC-SHA256", amz_date, scope, sha256(canonical)], "\n")

    signing_key =
      ("AWS4" <> config.s3_secret_access_key)
      |> hmac(date)
      |> hmac(config.s3_region)
      |> hmac("s3")
      |> hmac("aws4_request")

    signature = signing_key |> hmac(string) |> Base.encode16(case: :lower)

    authorization =
      "AWS4-HMAC-SHA256 Credential=#{config.s3_access_key_id}/#{scope}, SignedHeaders=#{names}, Signature=#{signature}"

    [{"authorization", authorization} | headers]
  end

  defp canonical_path(""), do: "/"

  defp canonical_path(key),
    do: "/" <> (key |> String.split("/", trim: false) |> Enum.map_join("/", &encode/1))

  defp canonical_query(query) do
    query
    |> Enum.map(fn {key, value} -> {encode(key), encode(value)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp xml_text(body, name) when is_binary(body) and byte_size(body) <= @xml_limit do
    with :ok <- reject_xml_declarations(body),
         [_, value] <- Regex.run(element_text_regex(name), body),
         {:ok, decoded} <- decode_xml_text(value) do
      {:ok, decoded}
    else
      _error -> {:error, :invalid_xml_response}
    end
  end

  defp xml_text(_, _), do: {:error, :xml_response_too_large}

  defp xml_element?(body, name) when is_binary(body) and byte_size(body) <= @xml_limit do
    reject_xml_declarations(body) != :ok or Regex.match?(element_regex(name), body)
  end

  defp xml_element?(_, _), do: true

  defp reject_xml_declarations(body) do
    if String.contains?(body, "<!"),
      do: {:error, :external_entity_forbidden},
      else: :ok
  end

  defp element_text_regex(name),
    do:
      Regex.compile!(
        "<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?#{name}(?:\\s[^>]*)?>([^<]*)</(?:[A-Za-z_][A-Za-z0-9_.-]*:)?#{name}\\s*>"
      )

  defp element_regex(name),
    do: Regex.compile!("<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?#{name}(?:\\s|>|/)")

  defp decode_xml_text(value) do
    if Regex.match?(~r/&(?!amp;|lt;|gt;|quot;|apos;)/, value) do
      {:error, :unsupported_xml_entity}
    else
      {:ok,
       value
       |> String.replace("&amp;", "&")
       |> String.replace("&lt;", "<")
       |> String.replace("&gt;", ">")
       |> String.replace("&quot;", "\"")
       |> String.replace("&apos;", "'")}
    end
  end

  defp xml_escape(value),
    do:
      value
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")
      |> String.replace("'", "&apos;")

  defp ip_literal?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
