defmodule WhisperLogs.Logs do
  @moduledoc """
  The Logs context for managing log entries.
  """

  import Ecto.Query, warn: false

  alias WhisperLogs.DbAdapter
  alias WhisperLogs.Repo
  alias WhisperLogs.Logs.Log
  alias WhisperLogs.Logs.SearchParser

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
    case SearchParser.parse(search) do
      {:ok, []} -> query
      {:ok, tokens} -> Enum.reduce(tokens, query, &apply_search_token/2)
    end
  end

  @doc """
  Applies parsed search tokens to a query.
  Used by the alert evaluator to reuse search logic.
  """
  def apply_search_tokens(query, tokens) when is_list(tokens) do
    Enum.reduce(tokens, query, &apply_search_token/2)
  end

  @doc """
  Counts logs matching a search query within a time window.

  Returns the count, or 0 if the query is invalid/empty.

  ## Examples

      count_matches("level:error", 3600)  # errors in past hour
      count_matches("user_id:123", 86400) # logs for user in past 24h
  """
  def count_matches(search_query, window_seconds) when is_binary(search_query) do
    cutoff = DateTime.add(DateTime.utc_now(), -window_seconds, :second)

    case SearchParser.parse(search_query) do
      {:ok, []} ->
        0

      {:ok, tokens} ->
        Log
        |> where([l], l.timestamp >= ^cutoff)
        |> apply_search_tokens(tokens)
        |> Repo.aggregate(:count, :id)
    end
  end

  def count_matches(_, _), do: 0

  @doc """
  Returns the current maximum log ID, or nil if no logs exist.
  Used to set the baseline for new alerts to prevent retroactive triggering.
  """
  def max_log_id do
    Repo.aggregate(Log, :max, :id)
  end

  # Plain term: search message OR any metadata value
  defp apply_search_token({:term, term}, query) do
    pattern = SearchParser.escape_like(term)
    where(query, ^DbAdapter.text_search(pattern))
  end

  # Quoted phrase: same as term but preserves spaces
  defp apply_search_token({:phrase, phrase}, query) do
    pattern = SearchParser.escape_like(phrase)
    where(query, ^DbAdapter.text_search(pattern))
  end

  # Exclude quoted phrase: NOT in message AND NOT in metadata (preserves spaces)
  defp apply_search_token({:exclude_phrase, phrase}, query) do
    pattern = SearchParser.escape_like(phrase)
    where(query, ^DbAdapter.text_exclude(pattern))
  end

  # Exclude term: NOT in message AND NOT in metadata
  defp apply_search_token({:exclude, term}, query) do
    pattern = SearchParser.escape_like(term)
    where(query, ^DbAdapter.text_exclude(pattern))
  end

  # Metadata key:value filter (equality with ILIKE)
  defp apply_search_token({:metadata, key, :eq, value}, query) do
    pattern = SearchParser.escape_like(value)
    where(query, ^DbAdapter.json_ilike_fragment(:metadata, key, pattern))
  end

  # Metadata numeric comparisons: key:>value, key:>=value, key:<value, key:<=value
  defp apply_search_token({:metadata, key, op, value}, query)
       when op in [:gt, :gte, :lt, :lte] do
    case parse_numeric(value) do
      {:ok, num} ->
        where(query, ^DbAdapter.json_numeric_compare(:metadata, key, op, num))

      :error ->
        where(query, false)
    end
  end

  # Exclude metadata key:value (equality)
  defp apply_search_token({:exclude_metadata, key, :eq, value}, query) do
    pattern = SearchParser.escape_like(value)
    where(query, ^DbAdapter.json_not_ilike_fragment(:metadata, key, pattern))
  end

  # Exclude metadata numeric comparisons (negate the operator)
  defp apply_search_token({:exclude_metadata, key, op, value}, query)
       when op in [:gt, :gte, :lt, :lte] do
    case parse_numeric(value) do
      {:ok, num} ->
        where(query, ^DbAdapter.json_numeric_exclude(:metadata, key, op, num))

      :error ->
        query
    end
  end

  # Level filter - exact match on level field OR metadata.level
  defp apply_search_token({:level_filter, level}, query) do
    where(query, ^DbAdapter.level_eq(level))
  end

  defp apply_search_token({:exclude_level_filter, level}, query) do
    where(query, ^DbAdapter.level_neq(level))
  end

  # Timestamp filter - comparison on timestamp field
  defp apply_search_token({:timestamp_filter, :eq, datetime}, query) do
    # For equality on a date (no time component), match the entire day
    # For datetime, match within the same second
    start_dt = DateTime.truncate(datetime, :second)
    end_dt = DateTime.add(start_dt, 1, :second)
    where(query, [l], l.timestamp >= ^start_dt and l.timestamp < ^end_dt)
  end

  defp apply_search_token({:timestamp_filter, :gt, datetime}, query) do
    where(query, [l], l.timestamp > ^datetime)
  end

  defp apply_search_token({:timestamp_filter, :gte, datetime}, query) do
    where(query, [l], l.timestamp >= ^datetime)
  end

  defp apply_search_token({:timestamp_filter, :lt, datetime}, query) do
    where(query, [l], l.timestamp < ^datetime)
  end

  defp apply_search_token({:timestamp_filter, :lte, datetime}, query) do
    where(query, [l], l.timestamp <= ^datetime)
  end

  # Exclude timestamp filter - negate the condition
  defp apply_search_token({:exclude_timestamp_filter, :eq, datetime}, query) do
    start_dt = DateTime.truncate(datetime, :second)
    end_dt = DateTime.add(start_dt, 1, :second)
    where(query, [l], l.timestamp < ^start_dt or l.timestamp >= ^end_dt)
  end

  defp apply_search_token({:exclude_timestamp_filter, :gt, datetime}, query) do
    where(query, [l], l.timestamp <= ^datetime)
  end

  defp apply_search_token({:exclude_timestamp_filter, :gte, datetime}, query) do
    where(query, [l], l.timestamp < ^datetime)
  end

  defp apply_search_token({:exclude_timestamp_filter, :lt, datetime}, query) do
    where(query, [l], l.timestamp >= ^datetime)
  end

  defp apply_search_token({:exclude_timestamp_filter, :lte, datetime}, query) do
    where(query, [l], l.timestamp > ^datetime)
  end

  # Source filter - ILIKE pattern match on source field OR metadata.source
  defp apply_search_token({:source_filter, pattern}, query) do
    like_pattern = SearchParser.escape_like(pattern)
    where(query, ^DbAdapter.source_match(like_pattern))
  end

  defp apply_search_token({:exclude_source_filter, pattern}, query) do
    like_pattern = SearchParser.escape_like(pattern)
    where(query, ^DbAdapter.source_exclude(like_pattern))
  end

  defp filter_request_id(query, nil), do: query
  defp filter_request_id(query, ""), do: query

  defp filter_request_id(query, request_id) do
    where(query, ^DbAdapter.request_id_eq(request_id))
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
  Returns the timestamp of the oldest log in the database.
  Returns nil if no logs exist.
  """
  def oldest_log_timestamp do
    Repo.aggregate(Log, :min, :timestamp)
  end

  @doc """
  Returns hourly log volume for the past N hours.
  Returns list of `{datetime, count, bytes}` tuples.
  """
  def volume_by_hour(hours \\ 48) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours, :hour)
    trunc = DbAdapter.trunc_hour()
    volume_select = DbAdapter.volume_select_hour()

    Log
    |> where([l], l.timestamp >= ^cutoff)
    |> group_by([l], ^trunc)
    |> select([l], ^volume_select)
    |> order_by(^[asc: trunc])
    |> Repo.all()
    |> Enum.map(fn %{timestamp: ts, count: c, bytes: b} -> {ts, c, b} end)
  end

  @doc """
  Returns daily log volume for the past N days.
  Returns list of `{datetime, count, bytes}` tuples.
  """
  def volume_by_day(days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day)
    trunc = DbAdapter.trunc_day()
    volume_select = DbAdapter.volume_select_day()

    Log
    |> where([l], l.timestamp >= ^cutoff)
    |> group_by([l], ^trunc)
    |> select([l], ^volume_select)
    |> order_by(^[asc: trunc])
    |> Repo.all()
    |> Enum.map(fn %{timestamp: ts, count: c, bytes: b} -> {ts, c, b} end)
  end

  @doc """
  Returns monthly log volume for the past N months.
  Returns list of `{datetime, count, bytes}` tuples.
  """
  def volume_by_month(months \\ 12) do
    cutoff = DateTime.utc_now() |> DateTime.add(-months * 30, :day)
    trunc = DbAdapter.trunc_month()
    volume_select = DbAdapter.volume_select_month()

    Log
    |> where([l], l.timestamp >= ^cutoff)
    |> group_by([l], ^trunc)
    |> select([l], ^volume_select)
    |> order_by(^[asc: trunc])
    |> Repo.all()
    |> Enum.map(fn %{timestamp: ts, count: c, bytes: b} -> {ts, c, b} end)
  end

  @doc """
  Returns total volume from the past N hours for projection calculations.
  Returns `{count, bytes}` tuple.
  """
  def volume_last_n_hours(hours) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours, :hour)
    volume_select = DbAdapter.volume_select_total()

    result =
      Log
      |> where([l], l.timestamp >= ^cutoff)
      |> select([l], ^volume_select)
      |> Repo.one()

    case result do
      nil -> {0, 0}
      %{count: nil, bytes: nil} -> {0, 0}
      %{count: count, bytes: bytes} -> {count, bytes || 0}
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

  defp parse_numeric(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} ->
        # SQLite doesn't support Decimal type, convert to float
        num = if DbAdapter.sqlite?(), do: Decimal.to_float(decimal), else: decimal
        {:ok, num}

      _ ->
        :error
    end
  end

  defp parse_numeric(_), do: :error
end
