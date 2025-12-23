defmodule WhisperLogs.Logs do
  @moduledoc """
  The Logs context for managing log entries.
  """

  import Ecto.Query, warn: false
  alias WhisperLogs.Repo
  alias WhisperLogs.Logs.Log

  @pubsub WhisperLogs.PubSub
  @topic "logs"

  @doc """
  Inserts a batch of logs for a given source.

  Returns `{count, nil}` where count is the number of inserted logs.
  """
  def insert_batch(source, logs) when is_binary(source) and is_list(logs) do
    now = DateTime.utc_now()

    entries =
      Enum.map(logs, fn log ->
        base_metadata = log["metadata"] || %{}

        metadata =
          if request_id = log["request_id"] do
            Map.put(base_metadata, "request_id", request_id)
          else
            base_metadata
          end

        %{
          timestamp: parse_timestamp(log["timestamp"]) || now,
          level: normalize_level(log["level"]),
          message: log["message"] || "",
          metadata: metadata,
          source: source,
          inserted_at: now
        }
      end)

    {count, inserted} =
      Repo.insert_all(Log, entries,
        returning: [
          :id,
          :timestamp,
          :level,
          :message,
          :metadata,
          :source,
          :inserted_at
        ]
      )

    # Broadcast each log for real-time updates
    Enum.each(inserted, fn log ->
      broadcast({:new_log, log})
    end)

    {count, nil}
  end

  @doc """
  Lists logs with optional filters.

  ## Options

    * `:from` - Start of time range (DateTime)
    * `:to` - End of time range (DateTime)
    * `:levels` - List of levels to include
    * `:sources` - List of sources to include
    * `:search` - Text search on message (ILIKE)
    * `:request_id` - Exact match on request_id
    * `:limit` - Max number of logs to return (default: 100)

  """
  def list_logs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Log
    |> order_by([l], desc: l.timestamp, desc: l.id)
    |> apply_filters(opts)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Lists logs older than the given cursor.
  Used for infinite scroll - loading older logs when scrolling up.

  Cursor is a tuple `{timestamp, id}` for stable pagination.
  Returns logs in descending order (newest first within batch).
  """
  def list_logs_before({timestamp, id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Log
    |> where([l], l.timestamp < ^timestamp or (l.timestamp == ^timestamp and l.id < ^id))
    |> order_by([l], desc: l.timestamp, desc: l.id)
    |> apply_filters(opts)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Lists logs newer than the given cursor.
  Used for infinite scroll - loading newer logs when scrolling down.

  Cursor is a tuple `{timestamp, id}` for stable pagination.
  Returns logs in ascending order (oldest first within batch).
  """
  def list_logs_after({timestamp, id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Log
    |> where([l], l.timestamp > ^timestamp or (l.timestamp == ^timestamp and l.id > ^id))
    |> order_by([l], asc: l.timestamp, asc: l.id)
    |> apply_filters(opts)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Lists logs around a specific log entry for context viewing.
  Returns logs centered around the target, with half before and half after.

  Cursor is a tuple `{timestamp, id}` for the target log.
  """
  def list_logs_around({timestamp, id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    half = div(limit, 2)

    # Get logs before (including target), descending then reverse
    before_logs =
      Log
      |> where([l], l.timestamp < ^timestamp or (l.timestamp == ^timestamp and l.id <= ^id))
      |> order_by([l], desc: l.timestamp, desc: l.id)
      |> limit(^half)
      |> Repo.all()
      |> Enum.reverse()

    # Get logs after target (excluding target), ascending
    after_logs =
      Log
      |> where([l], l.timestamp > ^timestamp or (l.timestamp == ^timestamp and l.id > ^id))
      |> order_by([l], asc: l.timestamp, asc: l.id)
      |> limit(^half)
      |> Repo.all()

    before_logs ++ after_logs
  end

  @doc """
  Checks if logs exist before the given cursor.
  """
  def has_logs_before?({timestamp, id}, opts \\ []) do
    Log
    |> where([l], l.timestamp < ^timestamp or (l.timestamp == ^timestamp and l.id < ^id))
    |> apply_filters(opts)
    |> limit(1)
    |> Repo.exists?()
  end

  @doc """
  Checks if logs exist after the given cursor.
  """
  def has_logs_after?({timestamp, id}, opts \\ []) do
    Log
    |> where([l], l.timestamp > ^timestamp or (l.timestamp == ^timestamp and l.id > ^id))
    |> apply_filters(opts)
    |> limit(1)
    |> Repo.exists?()
  end

  defp apply_filters(query, opts) do
    query
    |> filter_time_range(Keyword.get(opts, :from), Keyword.get(opts, :to))
    |> filter_levels(Keyword.get(opts, :levels))
    |> filter_sources(Keyword.get(opts, :sources))
    |> filter_search(Keyword.get(opts, :search))
    |> filter_request_id(Keyword.get(opts, :request_id))
  end

  defp filter_time_range(query, nil, nil), do: query
  defp filter_time_range(query, from, nil), do: where(query, [l], l.timestamp >= ^from)
  defp filter_time_range(query, nil, to), do: where(query, [l], l.timestamp <= ^to)

  defp filter_time_range(query, from, to),
    do: where(query, [l], l.timestamp >= ^from and l.timestamp <= ^to)

  defp filter_levels(query, nil), do: query
  defp filter_levels(query, []), do: where(query, false)
  defp filter_levels(query, levels), do: where(query, [l], l.level in ^levels)

  defp filter_sources(query, nil), do: query
  defp filter_sources(query, []), do: query
  defp filter_sources(query, sources), do: where(query, [l], l.source in ^sources)

  defp filter_search(query, nil), do: query
  defp filter_search(query, ""), do: query

  defp filter_search(query, search) do
    search_term = "%#{search}%"
    where(query, [l], ilike(l.message, ^search_term))
  end

  defp filter_request_id(query, nil), do: query
  defp filter_request_id(query, ""), do: query

  defp filter_request_id(query, request_id) do
    where(query, [l], fragment("?->>'request_id' = ?", l.metadata, ^request_id))
  end

  @doc """
  Gets a single log by ID.
  """
  def get_log(id) do
    Repo.get(Log, id)
  end

  @doc """
  Returns a list of distinct sources.
  """
  def list_sources do
    Log
    |> select([l], l.source)
    |> distinct(true)
    |> order_by([l], asc: l.source)
    |> Repo.all()
  end

  @doc """
  Returns the total count of logs in the database.
  """
  def count_logs do
    Repo.aggregate(Log, :count, :id)
  end

  @doc """
  Returns hourly log volume for the past N hours.
  Returns list of `{datetime, count, bytes}` tuples.
  """
  def volume_by_hour(hours \\ 48) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours, :hour)

    Log
    |> where([l], l.timestamp >= ^cutoff)
    |> group_by([l], fragment("date_trunc('hour', ?)", l.timestamp))
    |> select([l], {
      fragment("date_trunc('hour', ?)", l.timestamp),
      count(l.id),
      sum(
        fragment(
          "octet_length(?) + octet_length(coalesce(?::text, '{}'))",
          l.message,
          l.metadata
        )
      )
    })
    |> order_by([l], asc: fragment("date_trunc('hour', ?)", l.timestamp))
    |> Repo.all()
  end

  @doc """
  Returns daily log volume for the past N days.
  Returns list of `{datetime, count, bytes}` tuples.
  """
  def volume_by_day(days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day)

    Log
    |> where([l], l.timestamp >= ^cutoff)
    |> group_by([l], fragment("date_trunc('day', ?)", l.timestamp))
    |> select([l], {
      fragment("date_trunc('day', ?)", l.timestamp),
      count(l.id),
      sum(
        fragment(
          "octet_length(?) + octet_length(coalesce(?::text, '{}'))",
          l.message,
          l.metadata
        )
      )
    })
    |> order_by([l], asc: fragment("date_trunc('day', ?)", l.timestamp))
    |> Repo.all()
  end

  @doc """
  Returns monthly log volume for the past N months.
  Returns list of `{datetime, count, bytes}` tuples.
  """
  def volume_by_month(months \\ 12) do
    cutoff = DateTime.utc_now() |> DateTime.add(-months * 30, :day)

    Log
    |> where([l], l.timestamp >= ^cutoff)
    |> group_by([l], fragment("date_trunc('month', ?)", l.timestamp))
    |> select([l], {
      fragment("date_trunc('month', ?)", l.timestamp),
      count(l.id),
      sum(
        fragment(
          "octet_length(?) + octet_length(coalesce(?::text, '{}'))",
          l.message,
          l.metadata
        )
      )
    })
    |> order_by([l], asc: fragment("date_trunc('month', ?)", l.timestamp))
    |> Repo.all()
  end

  @doc """
  Returns total volume from the past N hours for projection calculations.
  Returns `{count, bytes}` tuple.
  """
  def volume_last_n_hours(hours) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours, :hour)

    Log
    |> where([l], l.timestamp >= ^cutoff)
    |> select([l], {
      count(l.id),
      sum(
        fragment(
          "octet_length(?) + octet_length(coalesce(?::text, '{}'))",
          l.message,
          l.metadata
        )
      )
    })
    |> Repo.one()
    |> case do
      {nil, nil} -> {0, 0}
      {count, bytes} -> {count, bytes || 0}
    end
  end

  @doc """
  Deletes logs older than the given datetime.

  Returns `{count, nil}` where count is the number of deleted logs.
  """
  def delete_before(%DateTime{} = cutoff) do
    Log
    |> where([l], l.timestamp < ^cutoff)
    |> Repo.delete_all()
  end

  @doc """
  Subscribes to new log events.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Broadcasts a log event to subscribers.
  """
  def broadcast(message) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, message)
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  defp normalize_level(level) when level in ~w(debug info warning error), do: level
  defp normalize_level("warn"), do: "warning"
  defp normalize_level(_), do: "info"
end
