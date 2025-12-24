defmodule WhisperLogs.LogsFixtures do
  @moduledoc """
  Test helpers for creating log entries via the `WhisperLogs.Logs` context.
  """

  alias WhisperLogs.Logs

  @doc """
  Creates a single log entry.

  Returns the created log struct.

  ## Examples

      log_fixture()
      log_fixture("my-source")
      log_fixture("my-source", level: "error", message: "Something broke")
  """
  def log_fixture(source \\ "test-source", attrs \\ []) do
    timestamp = Keyword.get(attrs, :timestamp, DateTime.utc_now())
    level = Keyword.get(attrs, :level, "info")
    # Use a unique message for reliable retrieval
    unique_id = System.unique_integer([:positive, :monotonic])
    message = Keyword.get(attrs, :message, "Test log message #{unique_id}")
    metadata = Keyword.get(attrs, :metadata, %{})
    # Add a unique marker to metadata for retrieval
    metadata_with_marker = Map.put(metadata, "_test_marker", unique_id)

    log_data = %{
      "timestamp" => DateTime.to_iso8601(timestamp),
      "level" => level,
      "message" => message,
      "metadata" => metadata_with_marker
    }

    {1, _} = Logs.insert_batch(source, [log_data])

    # Fetch by searching for our unique marker
    [log] = Logs.list_logs(sources: [source], search: "_test_marker:#{unique_id}", limit: 1)
    log
  end

  @doc """
  Creates multiple log entries.

  Returns the list of created log structs (newest first).

  ## Examples

      logs_fixture()  # 10 logs with random levels
      logs_fixture("my-source", 5)
      logs_fixture("my-source", 5, level: "error")
  """
  def logs_fixture(source \\ "test-source", count \\ 10, attrs \\ []) do
    base_time = DateTime.utc_now()
    level = Keyword.get(attrs, :level)
    metadata = Keyword.get(attrs, :metadata, %{})

    logs =
      for i <- 1..count do
        %{
          "timestamp" => DateTime.to_iso8601(DateTime.add(base_time, -i, :minute)),
          "level" => level || Enum.random(~w(debug info warning error)),
          "message" => Keyword.get(attrs, :message, "Test log #{i}"),
          "metadata" => metadata
        }
      end

    {^count, _} = Logs.insert_batch(source, logs)

    Logs.list_logs(sources: [source], limit: count)
  end

  @doc """
  Creates logs with specific timestamps for time-range testing.

  Returns logs in descending timestamp order.
  """
  def logs_with_timestamps(source \\ "test-source", timestamps) when is_list(timestamps) do
    logs =
      Enum.with_index(timestamps, fn ts, i ->
        %{
          "timestamp" => DateTime.to_iso8601(ts),
          "level" => "info",
          "message" => "Timed log #{i}"
        }
      end)

    count = length(logs)
    {^count, _} = Logs.insert_batch(source, logs)

    Logs.list_logs(sources: [source], limit: count)
  end
end
