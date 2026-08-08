defmodule WhisperLogs.Exports.ExporterTest do
  use WhisperLogs.DataCase, async: false

  import ExUnit.CaptureLog

  alias WhisperLogs.Exports
  alias WhisperLogs.Exports.Exporter
  alias WhisperLogs.Exports.S3ClientMock

  import WhisperLogs.AccountsFixtures
  import WhisperLogs.ExportsFixtures
  import WhisperLogs.LogsFixtures

  describe "local destination export" do
    test "exports logs to gzipped JSONL file" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)
      export_dir = Exports.destination_path(destination)

      # Create some logs
      for i <- 1..5 do
        log_fixture("test-source", level: "info", message: "Log message #{i}")
      end

      # Create job with time range that includes our logs
      now = DateTime.utc_now()
      from = DateTime.add(now, -1, :hour)

      {:ok, job} =
        Exports.create_manual_job(scope, destination.id, %{
          from_timestamp: from,
          to_timestamp: now
        })

      # Run the export
      Exporter.run_export(job)

      # Verify job was updated
      updated_job = Exports.get_export_job(scope, job.id)
      assert updated_job.status == "completed"
      assert updated_job.started_at != nil
      assert updated_job.completed_at != nil
      assert updated_job.log_count >= 5
      assert updated_job.file_size_bytes > 0
      assert updated_job.file_name =~ ~r/\.jsonl\.gz$/

      # Verify file exists
      export_path = Path.join(export_dir, updated_job.file_name)
      assert File.exists?(export_path)

      # Verify file contents (decompress and check)
      {:ok, compressed} = File.read(export_path)
      decompressed = :zlib.gunzip(compressed)
      lines = String.split(decompressed, "\n", trim: true)
      assert length(lines) >= 5

      # Each line should be valid JSON
      for line <- lines do
        {:ok, parsed} = Jason.decode(line)
        assert Map.has_key?(parsed, "id")
        assert Map.has_key?(parsed, "timestamp")
        assert Map.has_key?(parsed, "level")
        assert Map.has_key?(parsed, "message")
      end

      # Clean up
      File.rm_rf!(export_dir)
    end

    test "exports empty file when no logs match time range" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)
      export_dir = Exports.destination_path(destination)

      # Create job for a time range with no logs
      now = DateTime.utc_now()
      future = DateTime.add(now, 1, :hour)

      {:ok, job} =
        Exports.create_manual_job(scope, destination.id, %{
          from_timestamp: now,
          to_timestamp: future
        })

      Exporter.run_export(job)

      updated_job = Exports.get_export_job(scope, job.id)
      assert updated_job.status == "completed"
      assert updated_job.log_count == 0

      # Clean up
      File.rm_rf!(export_dir)
    end

    test "generates proper filename based on date range" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)
      export_dir = Exports.destination_path(destination)

      # Use specific dates
      from = ~U[2024-01-15 00:00:00Z]
      to = ~U[2024-01-20 23:59:59Z]

      {:ok, job} =
        Exports.create_manual_job(scope, destination.id, %{
          from_timestamp: from,
          to_timestamp: to
        })

      Exporter.run_export(job)

      updated_job = Exports.get_export_job(scope, job.id)
      assert updated_job.file_name == "whisperlogs_20240115_to_20240120_#{job.id}.jsonl.gz"

      # Clean up
      File.rm_rf!(export_dir)
    end
  end

  describe "S3 destination export" do
    setup do
      # Configure the mock S3 client
      Application.put_env(:whisperlogs, :s3_client, S3ClientMock)
      on_exit(fn -> Application.delete_env(:whisperlogs, :s3_client) end)
      :ok
    end

    test "uploads to S3 with correct key" do
      scope = user_scope_fixture()

      destination =
        s3_destination_fixture(scope,
          bucket: "my-bucket",
          prefix: "logs/archive"
        )

      # Create some logs
      for i <- 1..3 do
        log_fixture("test-source", level: "info", message: "S3 test log #{i}")
      end

      now = DateTime.utc_now()

      {:ok, job} =
        Exports.create_manual_job(scope, destination.id, %{
          from_timestamp: DateTime.add(now, -1, :hour),
          to_timestamp: now
        })

      Exporter.run_export(job)

      # Verify job completed
      updated_job = Exports.get_export_job(scope, job.id)
      assert updated_job.status == "completed"

      # Verify S3 was called with correct params
      assert_received {:s3_put_object, config, key, body, opts}
      assert config.s3_bucket == "my-bucket"
      assert String.starts_with?(key, "logs/archive/")
      assert String.ends_with?(key, ".jsonl.gz")
      assert is_binary(body)
      assert Keyword.get(opts, :content_type) == "application/gzip"
    end

    test "handles S3 upload failure" do
      scope = user_scope_fixture()
      destination = s3_destination_fixture(scope)

      {:ok, job} =
        Exports.create_manual_job(scope, destination.id, %{
          from_timestamp: DateTime.add(DateTime.utc_now(), -1, :hour),
          to_timestamp: DateTime.utc_now()
        })

      # Configure mock to return error
      S3ClientMock.set_response(:error)

      log =
        capture_log(fn ->
          Exporter.run_export(job)
        end)

      assert log =~ "S3 upload failed"

      updated_job = Exports.get_export_job(scope, job.id)
      assert updated_job.status == "failed"
      assert updated_job.error_message =~ "S3 error"

      # Reset for other tests
      S3ClientMock.set_response(:ok)
    end

    test "uses empty prefix correctly" do
      scope = user_scope_fixture()

      destination =
        s3_destination_fixture(scope,
          bucket: "test-bucket",
          prefix: ""
        )

      log_fixture("test-source", level: "info", message: "Test log")

      {:ok, job} =
        Exports.create_manual_job(scope, destination.id, %{
          from_timestamp: DateTime.add(DateTime.utc_now(), -1, :hour),
          to_timestamp: DateTime.utc_now()
        })

      Exporter.run_export(job)

      assert_received {:s3_put_object, _config, key, _body, _opts}
      # Key should not have a prefix
      refute String.starts_with?(key, "/")
      assert String.starts_with?(key, "whisperlogs_")
    end
  end

  describe "job status updates" do
    test "sets status to running before starting" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)
      export_dir = Exports.destination_path(destination)

      {:ok, job} =
        Exports.create_manual_job(scope, destination.id, %{
          from_timestamp: DateTime.add(DateTime.utc_now(), -1, :hour),
          to_timestamp: DateTime.utc_now()
        })

      # Initially pending
      assert job.status == "pending"

      Exporter.run_export(job)

      updated_job = Exports.get_export_job(scope, job.id)
      # After completion, should be completed or failed, not running
      assert updated_job.status in ["completed", "failed"]
      assert updated_job.started_at != nil

      # Clean up
      File.rm_rf!(export_dir)
    end
  end
end
