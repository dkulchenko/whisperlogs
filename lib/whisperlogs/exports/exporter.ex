defmodule WhisperLogs.Exports.Exporter do
  @moduledoc "Runs one bounded export job synchronously."
  require Logger

  alias WhisperLogs.Exports
  alias WhisperLogs.Exports.{ExportDestination, ExportJob, Workspace}
  alias WhisperLogs.Repo

  def run_export(%ExportJob{} = original_job) do
    job = Repo.preload(original_job, :export_destination)
    limits = WhisperLogs.Config.export_limits()
    deadline = System.monotonic_time(:millisecond) + limits.timeout_seconds * 1_000
    workspace = Workspace.create!(job.id)

    try do
      {:ok, job} =
        Exports.update_export_job(job, %{status: "running", started_at: DateTime.utc_now()})

      filename = filename(job)
      {file, path} = Workspace.create_archive!(workspace, filename)
      {count, size} = write_archive(file, path, job, limits, deadline)
      :ok = upload(job.export_destination, path, filename, deadline)

      Exports.update_export_job(job, %{
        status: "completed",
        completed_at: DateTime.utc_now(),
        file_name: filename,
        file_size_bytes: size,
        log_count: count,
        error_message: nil
      })
    rescue
      error ->
        reason = stable_error(error)
        Logger.error("Export job #{job.id} failed: #{reason}")

        Exports.update_export_job(job, %{
          status: "failed",
          completed_at: DateTime.utc_now(),
          error_message: reason
        })
    after
      Workspace.cleanup(workspace)
    end
  end

  defp write_archive(file, path, job, limits, deadline) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)

    result =
      try do
        enforce_deadline!(deadline)

        Repo.transaction(
          fn ->
            Exports.stream_logs_for_export(job.from_timestamp, job.to_timestamp, job.trigger)
            |> Enum.reduce(0, fn log, count ->
              enforce_deadline!(deadline)
              if count >= limits.max_rows, do: raise("export row limit exceeded")
              line = Jason.encode!(log_to_map(log)) <> "\n"
              :ok = write_compressed(file, :zlib.deflate(z, line))
              enforce_size!(path, limits.max_compressed_bytes)
              count + 1
            end)
          end,
          timeout: positive_remaining(deadline)
        )
      after
        :ok = write_compressed(file, :zlib.deflate(z, "", :finish))
        :zlib.deflateEnd(z)
        :zlib.close(z)
        :ok = File.close(file)
      end

    count =
      case result do
        {:ok, value} -> value
        {:error, reason} -> raise "database export failed: #{inspect(reason)}"
      end

    size = File.stat!(path).size
    if size > limits.max_compressed_bytes, do: raise("export compressed-byte limit exceeded")
    {count, size}
  end

  defp write_compressed(file, data) do
    :ok = IO.binwrite(file, data)
  end

  defp enforce_size!(path, max) do
    if File.stat!(path).size > max, do: raise("export compressed-byte limit exceeded")
  end

  defp upload(
         %ExportDestination{destination_type: "local"} = destination,
         path,
         filename,
         deadline
       ) do
    target_dir =
      destination |> Exports.destination_path() |> Workspace.ensure_local_destination!()

    target = Path.join(target_dir, filename)
    {:ok, output} = File.open(target, [:write, :binary, :exclusive])
    :ok = File.chmod(target, 0o600)

    try do
      try do
        source = File.open!(path, [:read, :binary])

        try do
          copy_bounded(source, output, deadline)
        after
          File.close(source)
        end
      after
        File.close(output)
      end
    rescue
      error ->
        File.rm(target)
        reraise error, __STACKTRACE__
    end
  end

  defp upload(%ExportDestination{destination_type: "s3"} = destination, path, filename, deadline) do
    key =
      if destination.s3_prefix in [nil, ""],
        do: filename,
        else: "#{String.trim(destination.s3_prefix, "/")}/#{filename}"

    client = Application.get_env(:whisperlogs, :s3_client, WhisperLogs.Exports.S3Client)

    case client.upload_file(destination, key, path, deadline) do
      :ok -> :ok
      {:error, reason} -> raise "S3 upload failed: #{inspect(reason)}"
    end
  end

  defp filename(job),
    do:
      "whisperlogs_#{Calendar.strftime(job.from_timestamp, "%Y%m%d")}_to_#{Calendar.strftime(job.to_timestamp, "%Y%m%d")}_#{job.id}.jsonl.gz"

  defp log_to_map(log),
    do: %{
      id: log.id,
      timestamp: DateTime.to_iso8601(log.timestamp),
      level: log.level,
      message: log.message,
      metadata: log.metadata,
      source: log.source,
      inserted_at: DateTime.to_iso8601(log.inserted_at)
    }

  defp enforce_deadline!(deadline),
    do: if(remaining(deadline) <= 0, do: raise("export deadline exceeded"), else: :ok)

  defp copy_bounded(source, output, deadline) do
    enforce_deadline!(deadline)

    case IO.binread(source, 1_048_576) do
      :eof ->
        :ok

      {:error, reason} ->
        raise "local export read failed: #{inspect(reason)}"

      chunk ->
        :ok = IO.binwrite(output, chunk)
        copy_bounded(source, output, deadline)
    end
  end

  defp remaining(deadline), do: deadline - System.monotonic_time(:millisecond)
  defp positive_remaining(deadline), do: max(remaining(deadline), 1)
  defp stable_error(error), do: error |> Exception.message() |> String.slice(0, 500)
end
