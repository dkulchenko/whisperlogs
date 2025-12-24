defmodule WhisperLogs.ExportsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `WhisperLogs.Exports` context.
  """

  alias WhisperLogs.Exports
  import WhisperLogs.AccountsFixtures

  @doc """
  Creates a local export destination.

  ## Examples

      local_destination_fixture(scope)
      local_destination_fixture(scope, local_path: "/tmp/exports")
  """
  def local_destination_fixture(scope \\ nil, attrs \\ []) do
    scope = scope || user_scope_fixture()
    name = Keyword.get(attrs, :name, "Test Local Destination #{System.unique_integer()}")
    local_path = Keyword.get(attrs, :local_path, System.tmp_dir!())
    enabled = Keyword.get(attrs, :enabled, true)

    {:ok, destination} =
      Exports.create_export_destination(scope, %{
        name: name,
        destination_type: "local",
        enabled: enabled,
        local_path: local_path,
        auto_export_enabled: Keyword.get(attrs, :auto_export_enabled, false),
        auto_export_age_days: Keyword.get(attrs, :auto_export_age_days)
      })

    destination
  end

  @doc """
  Creates an S3 export destination.

  ## Examples

      s3_destination_fixture(scope)
      s3_destination_fixture(scope, bucket: "my-bucket")
  """
  def s3_destination_fixture(scope \\ nil, attrs \\ []) do
    scope = scope || user_scope_fixture()
    name = Keyword.get(attrs, :name, "Test S3 Destination #{System.unique_integer()}")
    enabled = Keyword.get(attrs, :enabled, true)

    {:ok, destination} =
      Exports.create_export_destination(scope, %{
        name: name,
        destination_type: "s3",
        enabled: enabled,
        s3_endpoint: Keyword.get(attrs, :endpoint, "https://s3.amazonaws.com"),
        s3_bucket: Keyword.get(attrs, :bucket, "test-bucket"),
        s3_region: Keyword.get(attrs, :region, "us-east-1"),
        s3_access_key_id: Keyword.get(attrs, :access_key_id, "AKIAIOSFODNN7EXAMPLE"),
        s3_secret_access_key:
          Keyword.get(attrs, :secret_access_key, "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
        s3_prefix: Keyword.get(attrs, :prefix, "logs/"),
        auto_export_enabled: Keyword.get(attrs, :auto_export_enabled, false),
        auto_export_age_days: Keyword.get(attrs, :auto_export_age_days)
      })

    destination
  end

  @doc """
  Creates an export destination of any type.

  ## Examples

      export_destination_fixture(scope, destination_type: "local")
      export_destination_fixture(scope, destination_type: "s3")
  """
  def export_destination_fixture(scope \\ nil, attrs \\ []) do
    case Keyword.get(attrs, :destination_type, "local") do
      "local" -> local_destination_fixture(scope, attrs)
      "s3" -> s3_destination_fixture(scope, attrs)
    end
  end

  @doc """
  Creates an export job for a destination.

  ## Examples

      export_job_fixture(destination, scope)
      export_job_fixture(destination, scope, trigger: "scheduled")
  """
  def export_job_fixture(destination \\ nil, scope \\ nil, attrs \\ []) do
    scope = scope || user_scope_fixture()
    destination = destination || local_destination_fixture(scope)

    now = DateTime.utc_now()
    from = Keyword.get(attrs, :from_timestamp, DateTime.add(now, -7, :day))
    to = Keyword.get(attrs, :to_timestamp, now)
    trigger = Keyword.get(attrs, :trigger, "manual")

    {:ok, job} =
      Exports.create_export_job(destination, scope, %{
        trigger: trigger,
        from_timestamp: from,
        to_timestamp: to
      })

    job
  end

  @doc """
  Creates a completed export job (for testing last successful export).
  """
  def completed_export_job_fixture(destination \\ nil, scope \\ nil, attrs \\ []) do
    job = export_job_fixture(destination, scope, attrs)

    {:ok, completed_job} =
      Exports.update_export_job(job, %{
        status: "completed",
        file_name: Keyword.get(attrs, :file_name, "export-test.jsonl.gz"),
        file_size_bytes: Keyword.get(attrs, :file_size_bytes, 1024),
        log_count: Keyword.get(attrs, :log_count, 100),
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })

    completed_job
  end

  @doc """
  Creates a failed export job.
  """
  def failed_export_job_fixture(destination \\ nil, scope \\ nil, attrs \\ []) do
    job = export_job_fixture(destination, scope, attrs)

    {:ok, failed_job} =
      Exports.update_export_job(job, %{
        status: "failed",
        error_message: Keyword.get(attrs, :error_message, "Test error"),
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })

    failed_job
  end
end
