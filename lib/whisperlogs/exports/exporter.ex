defmodule WhisperLogs.Exports.Exporter do
  @moduledoc """
  Handles the actual export process - streaming logs to gzipped JSONL
  and uploading to the destination.
  """

  require Logger

  alias WhisperLogs.Exports
  alias WhisperLogs.Exports.{ExportDestination, ExportJob}
  alias WhisperLogs.Repo

  # Use configurable S3 client for testability
  defp s3_client do
    Application.get_env(:whisperlogs, :s3_client, WhisperLogs.Exports.S3Client)
  end

  @doc """
  Executes an export job.

  1. Updates job status to "running"
  2. Streams logs from database
  3. Writes to gzipped JSONL format
  4. Uploads to destination (local or S3)
  5. Updates job with results
  """
  def run_export(%ExportJob{} = job) do
    job = Repo.preload(job, :export_destination)
    destination = job.export_destination

    try do
      {:ok, job} =
        Exports.update_export_job(job, %{
          status: "running",
          started_at: DateTime.utc_now()
        })

      file_name = generate_filename(job.from_timestamp, job.to_timestamp)
      temp_path = Path.join(System.tmp_dir!(), file_name)

      # Stream logs and write to gzipped JSONL
      {log_count, file_size} = stream_to_gzipped_jsonl(job, temp_path)

      # Upload to destination
      case upload_to_destination(destination, temp_path, file_name) do
        :ok ->
          Exports.update_export_job(job, %{
            status: "completed",
            completed_at: DateTime.utc_now(),
            file_name: file_name,
            file_size_bytes: file_size,
            log_count: log_count
          })

          Logger.info(
            "Export job #{job.id} completed: #{log_count} logs, #{format_bytes(file_size)}"
          )

        {:error, reason} ->
          Exports.update_export_job(job, %{
            status: "failed",
            completed_at: DateTime.utc_now(),
            error_message: to_string(reason)
          })

          Logger.error("Export job #{job.id} failed to upload: #{inspect(reason)}")
      end

      # Clean up temp file
      File.rm(temp_path)
    rescue
      error ->
        Logger.error("Export job #{job.id} failed: #{Exception.message(error)}")

        Exports.update_export_job(job, %{
          status: "failed",
          completed_at: DateTime.utc_now(),
          error_message: Exception.message(error)
        })
    end
  end

  @doc """
  Runs an export job asynchronously in a new process.
  """
  def run_export_async(%ExportJob{} = job) do
    Task.start(fn -> run_export(job) end)
  end

  defp generate_filename(from, to) do
    from_str = Calendar.strftime(from, "%Y%m%d")
    to_str = Calendar.strftime(to, "%Y%m%d")
    "whisperlogs_#{from_str}_to_#{to_str}.jsonl.gz"
  end

  defp stream_to_gzipped_jsonl(job, temp_path) do
    # Open file with gzip compression
    {:ok, file} = :file.open(temp_path, [:write, :binary])
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)

    log_count =
      Repo.transaction(
        fn ->
          Exports.stream_logs_for_export(job.from_timestamp, job.to_timestamp)
          |> Enum.reduce(0, fn log, count ->
            json_line = Jason.encode!(log_to_map(log)) <> "\n"
            compressed = :zlib.deflate(z, json_line)
            :file.write(file, compressed)
            count + 1
          end)
        end,
        timeout: :infinity
      )

    # Finalize compression
    final = :zlib.deflate(z, "", :finish)
    :file.write(file, final)
    :zlib.deflateEnd(z)
    :zlib.close(z)
    :file.close(file)

    file_size =
      case File.stat(temp_path) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end

    case log_count do
      {:ok, count} -> {count, file_size}
      count when is_integer(count) -> {count, file_size}
    end
  end

  defp log_to_map(log) do
    %{
      id: log.id,
      timestamp: DateTime.to_iso8601(log.timestamp),
      level: log.level,
      message: log.message,
      metadata: log.metadata,
      source: log.source,
      inserted_at: DateTime.to_iso8601(log.inserted_at)
    }
  end

  defp upload_to_destination(
         %ExportDestination{destination_type: "local"} = dest,
         temp_path,
         file_name
       ) do
    target_dir = dest.local_path
    target_path = Path.join(target_dir, file_name)

    case File.mkdir_p(target_dir) do
      :ok ->
        case File.cp(temp_path, target_path) do
          :ok -> :ok
          {:error, reason} -> {:error, "Failed to copy file: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to create directory: #{inspect(reason)}"}
    end
  end

  defp upload_to_destination(
         %ExportDestination{destination_type: "s3"} = dest,
         temp_path,
         file_name
       ) do
    key =
      if dest.s3_prefix && dest.s3_prefix != "" do
        "#{dest.s3_prefix}/#{file_name}"
      else
        file_name
      end

    body = File.read!(temp_path)

    s3_client().put_object(dest, key, body, content_type: "application/gzip")
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
