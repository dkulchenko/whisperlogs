defmodule WhisperLogs.Exports.S3ClientTest do
  use ExUnit.Case, async: false

  alias WhisperLogs.Exports.{ExportDestination, S3Client}

  setup do
    old_hosts = Application.get_env(:whisperlogs, :s3_allowed_hosts)
    old_options = Application.get_env(:whisperlogs, :s3_req_options)
    Application.put_env(:whisperlogs, :s3_allowed_hosts, ["storage.example.com"])
    Application.put_env(:whisperlogs, :s3_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:whisperlogs, :s3_allowed_hosts, old_hosts)

      if old_options,
        do: Application.put_env(:whisperlogs, :s3_req_options, old_options),
        else: Application.delete_env(:whisperlogs, :s3_req_options)
    end)

    :ok
  end

  test "validates exact endpoint hosts and virtual-host-safe buckets" do
    assert :ok = S3Client.validate_destination(destination())

    assert {:error, :endpoint_not_allowlisted} =
             S3Client.validate_destination(destination(s3_endpoint: "sub.storage.example.com"))

    for bucket <- ["ab", "BadBucket", "127.0.0.1", "bad..bucket", "bad.-bucket"] do
      refute S3Client.valid_bucket?(bucket)
    end

    assert S3Client.valid_bucket?("logs-archive.example")
  end

  test "uploads sequential multipart requests with sorted canonical queries" do
    owner = self()
    path = temporary_file!(String.duplicate("a", 8 * 1024 * 1024 + 1))

    Req.Test.stub(__MODULE__, fn conn ->
      {body, conn} = read_body(conn)
      authorization = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
      send(owner, {:request, conn.method, conn.query_string, byte_size(body), authorization})

      case {conn.method, URI.decode_query(conn.query_string)} do
        {"POST", %{"uploads" => ""}} ->
          Plug.Conn.send_resp(
            conn,
            200,
            "<InitiateMultipartUploadResult><UploadId>upload-1</UploadId></InitiateMultipartUploadResult>"
          )

        {"PUT", %{"partNumber" => part}} ->
          conn
          |> Plug.Conn.put_resp_header("etag", "etag-#{part}")
          |> Plug.Conn.send_resp(200, "")

        {"POST", %{"uploadId" => "upload-1"}} ->
          assert body =~ "<PartNumber>1</PartNumber>"
          assert body =~ "<PartNumber>2</PartNumber>"
          Plug.Conn.send_resp(conn, 200, "<CompleteMultipartUploadResult/>")
      end
    end)

    assert :ok =
             S3Client.upload_file(
               destination(),
               "daily/log.jsonl.gz",
               path,
               System.monotonic_time(:millisecond) + 10_000
             )

    assert_receive {:request, "POST", "uploads=", 0, authorization}
    assert authorization =~ "SignedHeaders=host;x-amz-content-sha256;x-amz-date"
    assert_receive {:request, "PUT", "partNumber=1&uploadId=upload-1", 8_388_608, _}
    assert_receive {:request, "PUT", "partNumber=2&uploadId=upload-1", 1, _}
    assert_receive {:request, "POST", "uploadId=upload-1", _completion_bytes, _}
  end

  test "treats a successful completion Error body as failure and aborts" do
    owner = self()
    path = temporary_file!("archive")

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {conn.method, conn.query_string})

      case {conn.method, URI.decode_query(conn.query_string)} do
        {"POST", %{"uploads" => ""}} ->
          Plug.Conn.send_resp(
            conn,
            200,
            "<s3:UploadId xmlns:s3=\"urn:s3\">upload-2</s3:UploadId>"
          )

        {"PUT", _query} ->
          conn |> Plug.Conn.put_resp_header("etag", "etag-1") |> Plug.Conn.send_resp(200, "")

        {"POST", %{"uploadId" => "upload-2"}} ->
          Plug.Conn.send_resp(conn, 200, "<Error><Code>InternalError</Code></Error>")

        {"DELETE", %{"uploadId" => "upload-2"}} ->
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    assert {:error, :completion_error} =
             S3Client.upload_file(
               destination(),
               "archive.gz",
               path,
               System.monotonic_time(:millisecond) + 10_000
             )

    assert_receive {"DELETE", "uploadId=upload-2"}
  end

  test "rejects XML declarations that could define external entities" do
    path = temporary_file!("archive")

    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(
        conn,
        200,
        "<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><UploadId>&e;</UploadId>"
      )
    end)

    assert {:error, :invalid_xml_response} =
             S3Client.upload_file(
               destination(),
               "archive.gz",
               path,
               System.monotonic_time(:millisecond) + 10_000
             )
  end

  test "does not follow redirects during connection tests" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://attacker.example/")
      |> Plug.Conn.send_resp(301, "")
    end)

    assert {:error, :redirect_rejected} = S3Client.test_connection(destination())
  end

  defp destination(overrides \\ []) do
    struct!(
      ExportDestination,
      Keyword.merge(
        [
          s3_endpoint: "storage.example.com",
          s3_bucket: "my-bucket",
          s3_region: "us-west-2",
          s3_access_key_id: "access-key",
          s3_secret_access_key: "secret-key"
        ],
        overrides
      )
    )
  end

  defp temporary_file!(contents) do
    path =
      Path.join(System.tmp_dir!(), "whisperlogs-s3-#{System.unique_integer([:positive])}")

    File.write!(path, contents, [:exclusive])
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp read_body(conn, acc \\ []) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {IO.iodata_to_binary([acc, body]), conn}
      {:more, body, conn} -> read_body(conn, [acc, body])
    end
  end
end
