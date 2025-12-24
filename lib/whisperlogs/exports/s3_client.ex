defmodule WhisperLogs.Exports.S3Client do
  @moduledoc """
  Minimal S3-compatible client using Req with AWS Signature V4.

  Supports AWS S3, Backblaze B2, MinIO, and other S3-compatible services.
  """

  require Logger

  @doc """
  Uploads a file to S3.

  ## Config

    * `:endpoint` - S3 endpoint (e.g., "s3.amazonaws.com", "s3.us-west-000.backblazeb2.com")
    * `:bucket` - Bucket name
    * `:region` - AWS region (e.g., "us-east-1")
    * `:access_key_id` - Access key ID
    * `:secret_access_key` - Secret access key

  ## Options

    * `:content_type` - Content-Type header (default: "application/octet-stream")

  Returns `:ok` or `{:error, reason}`.
  """
  def put_object(config, key, body, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    now = DateTime.utc_now()

    url = build_url(config, key)
    headers = build_headers(config, "PUT", key, body, content_type, now)

    case Req.put(url, body: body, headers: headers, receive_timeout: 300_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.error("S3 upload failed: status=#{status}, body=#{inspect(body)}")
        {:error, "S3 returned status #{status}"}

      {:error, reason} ->
        Logger.error("S3 upload failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Tests connectivity to an S3 destination by checking if the bucket exists.

  Returns `:ok` or `{:error, reason}`.
  """
  def test_connection(config) do
    now = DateTime.utc_now()

    # Use HEAD request on bucket root to test connectivity
    url = build_bucket_url(config)
    headers = build_headers(config, "HEAD", "", "", "", now)

    case Req.head(url, headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 301}} ->
        {:error, "Bucket redirect - check region configuration"}

      {:ok, %{status: 403}} ->
        {:error, "Access denied - check credentials"}

      {:ok, %{status: 404}} ->
        {:error, "Bucket not found"}

      {:ok, %{status: status, body: body}} ->
        {:error, "S3 returned status #{status}: #{inspect(body)}"}

      {:error, %{reason: :nxdomain}} ->
        {:error, "DNS resolution failed - check endpoint"}

      {:error, %{reason: :timeout}} ->
        {:error, "Connection timeout"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # ===== URL Building =====

  defp build_url(config, key) do
    "https://#{config.s3_bucket}.#{config.s3_endpoint}/#{URI.encode(key)}"
  end

  defp build_bucket_url(config) do
    "https://#{config.s3_bucket}.#{config.s3_endpoint}/"
  end

  # ===== AWS Signature V4 =====

  defp build_headers(config, method, key, body, content_type, now) do
    date_stamp = format_date(now)
    amz_date = format_amz_date(now)
    payload_hash = hash_payload(body)

    host = "#{config.s3_bucket}.#{config.s3_endpoint}"

    base_headers =
      [
        {"host", host},
        {"x-amz-date", amz_date},
        {"x-amz-content-sha256", payload_hash}
      ]
      |> maybe_add_content_type(content_type, method)

    authorization =
      sign_request(
        method,
        "/" <> URI.encode(key),
        base_headers,
        payload_hash,
        config,
        date_stamp,
        amz_date
      )

    [{"authorization", authorization} | base_headers]
  end

  defp maybe_add_content_type(headers, "", _method), do: headers
  defp maybe_add_content_type(headers, _content_type, "HEAD"), do: headers

  defp maybe_add_content_type(headers, content_type, _method) do
    [{"content-type", content_type} | headers]
  end

  defp sign_request(method, path, headers, payload_hash, config, date_stamp, amz_date) do
    region = config.s3_region
    service = "s3"

    # Step 1: Create canonical request
    canonical_request = create_canonical_request(method, path, headers, payload_hash)

    # Step 2: Create string to sign
    credential_scope = "#{date_stamp}/#{region}/#{service}/aws4_request"
    string_to_sign = create_string_to_sign(amz_date, credential_scope, canonical_request)

    # Step 3: Calculate signature
    signing_key = derive_signing_key(config.s3_secret_access_key, date_stamp, region, service)
    signature = hmac_sha256_hex(signing_key, string_to_sign)

    # Step 4: Create authorization header
    signed_headers = headers |> Enum.map(fn {k, _} -> k end) |> Enum.sort() |> Enum.join(";")

    "AWS4-HMAC-SHA256 " <>
      "Credential=#{config.s3_access_key_id}/#{credential_scope}, " <>
      "SignedHeaders=#{signed_headers}, " <>
      "Signature=#{signature}"
  end

  defp create_canonical_request(method, path, headers, payload_hash) do
    sorted_headers = Enum.sort_by(headers, fn {k, _} -> k end)
    canonical_headers = Enum.map_join(sorted_headers, "\n", fn {k, v} -> "#{k}:#{v}" end)
    signed_headers = sorted_headers |> Enum.map(fn {k, _} -> k end) |> Enum.join(";")

    [
      method,
      path,
      "",
      canonical_headers,
      "",
      signed_headers,
      payload_hash
    ]
    |> Enum.join("\n")
  end

  defp create_string_to_sign(amz_date, credential_scope, canonical_request) do
    [
      "AWS4-HMAC-SHA256",
      amz_date,
      credential_scope,
      hash_sha256(canonical_request)
    ]
    |> Enum.join("\n")
  end

  defp derive_signing_key(secret_key, date_stamp, region, service) do
    ("AWS4" <> secret_key)
    |> hmac_sha256(date_stamp)
    |> hmac_sha256(region)
    |> hmac_sha256(service)
    |> hmac_sha256("aws4_request")
  end

  # ===== Crypto Helpers =====

  defp hmac_sha256(key, data) do
    :crypto.mac(:hmac, :sha256, key, data)
  end

  defp hmac_sha256_hex(key, data) do
    hmac_sha256(key, data) |> Base.encode16(case: :lower)
  end

  defp hash_sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp hash_payload(""), do: hash_sha256("")
  defp hash_payload(body) when is_binary(body), do: hash_sha256(body)

  # ===== Date Formatting =====

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y%m%d")
  end

  defp format_amz_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")
  end
end
