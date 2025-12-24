defmodule WhisperLogs.ExportsTest do
  use WhisperLogs.DataCase, async: true

  alias WhisperLogs.Exports

  import WhisperLogs.AccountsFixtures
  import WhisperLogs.ExportsFixtures
  import WhisperLogs.LogsFixtures

  # ===== Export Destination Tests =====

  describe "list_export_destinations/1" do
    test "returns destinations for scope" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)

      destinations = Exports.list_export_destinations(scope)
      assert length(destinations) == 1
      assert hd(destinations).id == destination.id
    end

    test "does not return destinations from other users" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      _destination1 = local_destination_fixture(scope1)
      destination2 = local_destination_fixture(scope2)

      destinations = Exports.list_export_destinations(scope2)
      assert length(destinations) == 1
      assert hd(destinations).id == destination2.id
    end
  end

  describe "get_export_destination/2" do
    test "returns destination for scope" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)

      result = Exports.get_export_destination(scope, destination.id)
      assert result.id == destination.id
    end

    test "returns nil for non-existent destination" do
      scope = user_scope_fixture()
      assert Exports.get_export_destination(scope, 999_999) == nil
    end

    test "returns nil for destination belonging to other user" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      destination = local_destination_fixture(scope1)

      assert Exports.get_export_destination(scope2, destination.id) == nil
    end
  end

  describe "get_export_destination!/2" do
    test "returns destination for scope" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)

      result = Exports.get_export_destination!(scope, destination.id)
      assert result.id == destination.id
    end

    test "raises for non-existent destination" do
      scope = user_scope_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        Exports.get_export_destination!(scope, 999_999)
      end
    end
  end

  describe "create_export_destination/2 with local type" do
    test "creates local destination with valid attributes" do
      scope = user_scope_fixture()

      {:ok, destination} =
        Exports.create_export_destination(scope, %{
          name: "My Local Export",
          destination_type: "local",
          local_path: "/tmp/exports"
        })

      assert destination.name == "My Local Export"
      assert destination.destination_type == "local"
      assert destination.local_path == "/tmp/exports"
      assert destination.enabled == true
    end

    test "validates local_path is required for local type" do
      scope = user_scope_fixture()

      {:error, changeset} =
        Exports.create_export_destination(scope, %{
          name: "Bad Local",
          destination_type: "local"
        })

      assert errors_on(changeset) |> Map.has_key?(:local_path)
    end

    test "validates local_path cannot contain .." do
      scope = user_scope_fixture()

      {:error, changeset} =
        Exports.create_export_destination(scope, %{
          name: "Bad Path",
          destination_type: "local",
          local_path: "/tmp/../etc"
        })

      assert errors_on(changeset) |> Map.has_key?(:local_path)
    end
  end

  describe "create_export_destination/2 with s3 type" do
    test "creates S3 destination with valid attributes" do
      scope = user_scope_fixture()

      {:ok, destination} =
        Exports.create_export_destination(scope, %{
          name: "My S3 Export",
          destination_type: "s3",
          s3_endpoint: "s3.amazonaws.com",
          s3_bucket: "my-bucket",
          s3_region: "us-east-1",
          s3_access_key_id: "AKIAIOSFODNN7EXAMPLE",
          s3_secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
          s3_prefix: "logs/"
        })

      assert destination.destination_type == "s3"
      assert destination.s3_bucket == "my-bucket"
    end

    test "validates S3 fields are required for s3 type" do
      scope = user_scope_fixture()

      {:error, changeset} =
        Exports.create_export_destination(scope, %{
          name: "Bad S3",
          destination_type: "s3"
        })

      errors = errors_on(changeset)
      assert Map.has_key?(errors, :s3_endpoint)
      assert Map.has_key?(errors, :s3_bucket)
      assert Map.has_key?(errors, :s3_region)
      assert Map.has_key?(errors, :s3_access_key_id)
      assert Map.has_key?(errors, :s3_secret_access_key)
    end
  end

  describe "update_export_destination/2" do
    test "updates destination attributes" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope, name: "Original")

      {:ok, updated} =
        Exports.update_export_destination(destination, %{
          name: "Updated"
        })

      assert updated.name == "Updated"
    end
  end

  describe "toggle_export_destination/1" do
    test "disables enabled destination" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope, enabled: true)

      {:ok, toggled} = Exports.toggle_export_destination(destination)

      assert toggled.enabled == false
    end

    test "enables disabled destination" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope, enabled: false)

      {:ok, toggled} = Exports.toggle_export_destination(destination)

      assert toggled.enabled == true
    end
  end

  describe "delete_export_destination/1" do
    test "deletes the destination" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)

      {:ok, _} = Exports.delete_export_destination(destination)

      assert Exports.get_export_destination(scope, destination.id) == nil
    end
  end

  describe "list_auto_export_destinations/0" do
    test "returns destinations with auto-export enabled" do
      scope = user_scope_fixture()

      {:ok, auto_enabled} =
        Exports.create_export_destination(scope, %{
          name: "Auto Export",
          destination_type: "local",
          local_path: "/tmp/exports",
          enabled: true,
          auto_export_enabled: true,
          auto_export_age_days: 7
        })

      _disabled =
        local_destination_fixture(scope,
          enabled: true,
          auto_export_enabled: false
        )

      destinations = Exports.list_auto_export_destinations()
      assert length(destinations) == 1
      assert hd(destinations).id == auto_enabled.id
    end

    test "excludes disabled destinations" do
      scope = user_scope_fixture()

      {:ok, _disabled} =
        Exports.create_export_destination(scope, %{
          name: "Disabled Auto",
          destination_type: "local",
          local_path: "/tmp/exports",
          enabled: false,
          auto_export_enabled: true,
          auto_export_age_days: 7
        })

      destinations = Exports.list_auto_export_destinations()
      assert destinations == []
    end
  end

  # ===== Export Job Tests =====

  describe "list_export_jobs/2" do
    test "returns jobs for scope" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)
      job = export_job_fixture(destination, scope)

      jobs = Exports.list_export_jobs(scope)
      assert length(jobs) == 1
      assert hd(jobs).id == job.id
    end

    test "preloads export_destination" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)
      _job = export_job_fixture(destination, scope)

      [job] = Exports.list_export_jobs(scope)
      assert Ecto.assoc_loaded?(job.export_destination)
    end

    test "respects limit option" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)
      for _ <- 1..5, do: export_job_fixture(destination, scope)

      jobs = Exports.list_export_jobs(scope, limit: 3)
      assert length(jobs) == 3
    end
  end

  describe "list_export_jobs_for_destination/2" do
    test "returns jobs for destination" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)
      job = export_job_fixture(destination, scope)

      jobs = Exports.list_export_jobs_for_destination(destination)
      assert length(jobs) == 1
      assert hd(jobs).id == job.id
    end
  end

  describe "get_export_job/2" do
    test "returns job for scope" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)
      job = export_job_fixture(destination, scope)

      result = Exports.get_export_job(scope, job.id)
      assert result.id == job.id
    end

    test "returns nil for job belonging to other user" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      destination = local_destination_fixture(scope1)
      job = export_job_fixture(destination, scope1)

      assert Exports.get_export_job(scope2, job.id) == nil
    end
  end

  describe "create_export_job/3" do
    test "creates job with valid attributes" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)

      now = DateTime.utc_now()

      {:ok, job} =
        Exports.create_export_job(destination, scope, %{
          trigger: "manual",
          from_timestamp: DateTime.add(now, -7, :day),
          to_timestamp: now
        })

      assert job.status == "pending"
      assert job.trigger == "manual"
    end

    test "validates date range" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)

      now = DateTime.utc_now()

      {:error, changeset} =
        Exports.create_export_job(destination, scope, %{
          trigger: "manual",
          from_timestamp: now,
          to_timestamp: DateTime.add(now, -1, :day)
        })

      assert errors_on(changeset) |> Map.has_key?(:to_timestamp)
    end

    test "validates trigger is manual or scheduled" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)

      now = DateTime.utc_now()

      {:error, changeset} =
        Exports.create_export_job(destination, scope, %{
          trigger: "invalid",
          from_timestamp: DateTime.add(now, -1, :day),
          to_timestamp: now
        })

      assert errors_on(changeset) |> Map.has_key?(:trigger)
    end
  end

  describe "update_export_job/2" do
    test "updates job status" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)
      job = export_job_fixture(destination, scope)

      {:ok, updated} =
        Exports.update_export_job(job, %{
          status: "running",
          started_at: DateTime.utc_now()
        })

      assert updated.status == "running"
    end

    test "can set completion details" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)
      job = export_job_fixture(destination, scope)

      {:ok, updated} =
        Exports.update_export_job(job, %{
          status: "completed",
          file_name: "export.jsonl.gz",
          file_size_bytes: 1024,
          log_count: 100,
          completed_at: DateTime.utc_now()
        })

      assert updated.status == "completed"
      assert updated.file_name == "export.jsonl.gz"
      assert updated.log_count == 100
    end

    test "can set error details" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)
      job = export_job_fixture(destination, scope)

      {:ok, updated} =
        Exports.update_export_job(job, %{
          status: "failed",
          error_message: "Connection refused",
          completed_at: DateTime.utc_now()
        })

      assert updated.status == "failed"
      assert updated.error_message == "Connection refused"
    end
  end

  describe "get_last_successful_export_end/1" do
    test "returns timestamp from last completed job" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)

      to_timestamp = DateTime.utc_now()

      _completed_job =
        completed_export_job_fixture(destination, scope, to_timestamp: to_timestamp)

      result = Exports.get_last_successful_export_end(destination)
      assert DateTime.compare(result, to_timestamp) == :eq
    end

    test "returns nil when no successful exports" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)
      _failed_job = failed_export_job_fixture(destination, scope)

      assert Exports.get_last_successful_export_end(destination) == nil
    end
  end

  describe "delete_jobs_before/1" do
    test "deletes jobs older than cutoff" do
      scope = user_scope_fixture()
      destination = local_destination_fixture(scope)
      _job = export_job_fixture(destination, scope)

      cutoff = DateTime.add(DateTime.utc_now(), 1, :hour)
      {count, _} = Exports.delete_jobs_before(cutoff)

      assert count == 1
      assert Exports.list_export_jobs(scope) == []
    end
  end

  # ===== Log Streaming Tests =====

  describe "stream_logs_for_export/2" do
    test "streams logs within time range" do
      now = DateTime.utc_now()
      from = DateTime.add(now, -2, :hour)
      to = now

      # Create logs within and outside the range
      _old_log = log_fixture("test-source", timestamp: DateTime.add(now, -3, :hour))
      in_range_log = log_fixture("test-source", timestamp: DateTime.add(now, -1, :hour))
      _future_log = log_fixture("test-source", timestamp: DateTime.add(now, 1, :hour))

      # Stream must be called within transaction
      logs =
        Repo.transaction(fn ->
          Exports.stream_logs_for_export(from, to)
          |> Enum.to_list()
        end)

      {:ok, logs} = logs
      assert length(logs) == 1
      assert hd(logs).id == in_range_log.id
    end

    test "orders by timestamp ascending" do
      now = DateTime.utc_now()
      from = DateTime.add(now, -2, :hour)
      to = now

      log2 = log_fixture("test-source", timestamp: DateTime.add(now, -30, :minute))
      log1 = log_fixture("test-source", timestamp: DateTime.add(now, -90, :minute))

      {:ok, logs} =
        Repo.transaction(fn ->
          Exports.stream_logs_for_export(from, to)
          |> Enum.to_list()
        end)

      assert length(logs) == 2
      assert hd(logs).id == log1.id
      assert List.last(logs).id == log2.id
    end
  end
end
