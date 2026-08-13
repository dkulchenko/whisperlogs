defmodule WhisperLogs.Logs do
  @moduledoc """
  The Logs context for managing log entries.
  """

  import Ecto.Query, warn: false

  alias WhisperLogs.DbAdapter
  alias WhisperLogs.Repo
  alias WhisperLogs.Accounts.{Scope, User}
  alias WhisperLogs.Logs.Log
  alias WhisperLogs.Logs.VolumeRollups
  alias WhisperLogs.Logs.SavedSearch
  alias WhisperLogs.Logs.SearchParser

  @pubsub WhisperLogs.PubSub
  @topic "logs"

  @doc """
  Inserts a batch of logs for a given source.

  Validates the complete batch before inserting anything.
  """
  def insert_batch(source, logs) when is_binary(source) and is_list(logs) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with :ok <- validate_batch_size(logs),
         {:ok, entries} <- validate_events(logs, source, observed_at) do
      {:ok, inserted} =
        Repo.transaction(fn ->
          {_count, inserted} =
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

          VolumeRollups.increment_batch!(inserted, observed_at)
          inserted
        end)

      broadcast({:new_logs, inserted})
      {:ok, inserted}
    end
  end

  def insert_batch(_source, _logs), do: {:error, %{field: :logs, reason: :invalid_batch}}

  defp validate_batch_size(logs) do
    max_batch_size = WhisperLogs.Config.receiver_limits().max_batch_size

    cond do
      logs == [] -> {:error, %{field: :logs, reason: :empty}}
      length(logs) > max_batch_size -> {:error, %{field: :logs, reason: :too_many}}
      true -> :ok
    end
  end

  defp validate_events(logs, source, observed_at) do
    logs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {event, index}, {:ok, entries} ->
      case validate_event(event, source, observed_at) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, error} -> {:halt, {:error, Map.put(error, :index, index)}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp validate_event(event, source, observed_at) when is_map(event) do
    limits = WhisperLogs.Config.receiver_limits()

    with :ok <- encoded_limit(event, limits.max_event_bytes, :event),
         {:ok, timestamp} <- event_timestamp(Map.get(event, "timestamp"), observed_at),
         {:ok, level} <- event_level(Map.get(event, "level")),
         {:ok, message} <- event_message(Map.get(event, "message"), limits),
         {:ok, metadata} <- event_metadata(event, limits),
         entry = %{
           timestamp: timestamp,
           level: level,
           message: message,
           metadata: metadata,
           source: source,
           inserted_at: observed_at
         },
         :ok <- encoded_limit(entry, limits.max_event_bytes, :event) do
      {:ok, entry}
    end
  end

  defp validate_event(_event, _source, _observed_at),
    do: {:error, %{field: :event, reason: :not_an_object}}

  defp event_timestamp(nil, observed_at), do: {:ok, observed_at}

  defp event_timestamp(timestamp, _observed_at) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
      _error -> {:error, %{field: :timestamp, reason: :invalid_rfc3339}}
    end
  end

  defp event_timestamp(_timestamp, _observed_at),
    do: {:error, %{field: :timestamp, reason: :invalid_type}}

  defp event_level(nil), do: {:ok, "info"}
  defp event_level("warn"), do: {:ok, "warning"}
  defp event_level(level) when level in ~w(debug info warning error), do: {:ok, level}

  defp event_level(level) when is_binary(level),
    do: {:error, %{field: :level, reason: :invalid_value}}

  defp event_level(_level), do: {:error, %{field: :level, reason: :invalid_type}}

  defp event_message(nil, _limits), do: {:ok, ""}

  defp event_message(message, limits) when is_binary(message) do
    cond do
      not String.valid?(message) ->
        {:error, %{field: :message, reason: :invalid_utf8}}

      byte_size(message) > limits.max_message_bytes ->
        {:error, %{field: :message, reason: :too_large}}

      true ->
        {:ok, message}
    end
  end

  defp event_message(_message, _limits),
    do: {:error, %{field: :message, reason: :invalid_type}}

  defp event_metadata(event, limits) do
    metadata = Map.get(event, "metadata") || %{}
    request_id = Map.get(event, "request_id")

    cond do
      not is_map(metadata) ->
        {:error, %{field: :metadata, reason: :not_an_object}}

      not is_nil(request_id) and not is_binary(request_id) ->
        {:error, %{field: :request_id, reason: :invalid_type}}

      is_binary(request_id) and not String.valid?(request_id) ->
        {:error, %{field: :request_id, reason: :invalid_utf8}}

      true ->
        metadata = if request_id, do: Map.put(metadata, "request_id", request_id), else: metadata

        with :ok <- validate_depth(metadata, limits.max_metadata_depth),
             :ok <- encoded_limit(metadata, limits.max_metadata_bytes, :metadata) do
          {:ok, metadata}
        end
    end
  end

  defp validate_depth(value, max_depth) do
    if json_depth(value) <= max_depth do
      :ok
    else
      {:error, %{field: :metadata, reason: :too_deep}}
    end
  end

  defp json_depth(value) when is_map(value) do
    child_depth = value |> Map.values() |> Enum.map(&json_depth/1) |> Enum.max(fn -> 0 end)
    1 + child_depth
  end

  defp json_depth(value) when is_list(value) do
    child_depth = value |> Enum.map(&json_depth/1) |> Enum.max(fn -> 0 end)
    1 + child_depth
  end

  defp json_depth(_value), do: 0

  defp encoded_limit(value, max_bytes, field) do
    size = value |> Jason.encode_to_iodata!() |> IO.iodata_length()

    if size <= max_bytes,
      do: :ok,
      else: {:error, %{field: field, reason: :too_large}}
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
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> apply_filters(opts)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Lists logs older than the given cursor.
  Used for infinite scroll - loading older logs when scrolling up.

  Cursor is an observed-time tuple `{inserted_at, id}` for stable pagination.
  Returns logs in descending order (newest first within batch).
  """
  def list_logs_before({inserted_at, id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Log
    |> where([l], l.inserted_at < ^inserted_at or (l.inserted_at == ^inserted_at and l.id < ^id))
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> apply_filters(opts)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Searches the shared log workspace for an authenticated caller.

  The query uses the same grammar as the Logs LiveView. Results are newest first and
  return one extra row internally to report whether another page exists.
  """
  def search_logs(scope, search, opts \\ [])

  def search_logs(%Scope{user: %User{}}, search, opts) when is_binary(search) do
    limits = WhisperLogs.Config.mcp_limits()
    limit = Keyword.get(opts, :limit, 50)
    before = Keyword.get(opts, :before)
    since = Keyword.get(opts, :since)
    until = Keyword.get(opts, :until)
    trimmed = String.trim(search)

    cond do
      byte_size(search) > limits.max_query_bytes ->
        {:error, :query_too_large}

      not is_integer(limit) or limit < 1 or limit > 100 ->
        {:error, :invalid_limit}

      not valid_timestamp_bounds?(since, until) ->
        {:error, :invalid_time_range}

      true ->
        case SearchParser.parse(search) do
          {:ok, []} when trimmed != "" ->
            {:error, :invalid_query}

          {:ok, tokens} ->
            query =
              Log
              |> maybe_before(before)
              |> filter_observed_time_range(since, until)
              |> order_by([l], desc: l.inserted_at, desc: l.id)
              |> apply_search_tokens(tokens)
              |> limit(^(limit + 1))

            logs = Repo.all(query, timeout: limits.query_timeout_ms)
            {:ok, %{logs: Enum.take(logs, limit), has_more: length(logs) > limit}}
        end
    end
  end

  def search_logs(_scope, _search, _opts), do: {:error, :unauthorized}

  defp maybe_before(query, nil), do: query

  defp maybe_before(query, {inserted_at, id}) do
    where(
      query,
      [l],
      l.inserted_at < ^inserted_at or (l.inserted_at == ^inserted_at and l.id < ^id)
    )
  end

  defp valid_timestamp_bounds?(nil, nil), do: true
  defp valid_timestamp_bounds?(%DateTime{}, nil), do: true
  defp valid_timestamp_bounds?(nil, %DateTime{}), do: true

  defp valid_timestamp_bounds?(%DateTime{} = since, %DateTime{} = until) do
    DateTime.compare(since, until) == :lt
  end

  defp valid_timestamp_bounds?(_since, _until), do: false

  defp filter_observed_time_range(query, nil, nil), do: query

  defp filter_observed_time_range(query, %DateTime{} = since, nil),
    do: where(query, [l], l.inserted_at >= ^since)

  defp filter_observed_time_range(query, nil, %DateTime{} = until),
    do: where(query, [l], l.inserted_at < ^until)

  defp filter_observed_time_range(query, %DateTime{} = since, %DateTime{} = until) do
    where(query, [l], l.inserted_at >= ^since and l.inserted_at < ^until)
  end

  @doc """
  Lists logs newer than the given cursor.
  Used for infinite scroll - loading newer logs when scrolling down.

  Cursor is an observed-time tuple `{inserted_at, id}` for stable pagination.
  Returns logs in ascending order (oldest first within batch).
  """
  def list_logs_after({inserted_at, id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Log
    |> where([l], l.inserted_at > ^inserted_at or (l.inserted_at == ^inserted_at and l.id > ^id))
    |> order_by([l], asc: l.inserted_at, asc: l.id)
    |> apply_filters(opts)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Lists logs around a specific log entry for context viewing.
  Returns logs centered around the target, with half before and half after.

  Cursor is an observed-time tuple `{inserted_at, id}` for the target log.
  """
  def list_logs_around({inserted_at, id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    half = div(limit, 2)

    # Get logs before (including target), descending then reverse
    before_logs =
      Log
      |> where(
        [l],
        l.inserted_at < ^inserted_at or (l.inserted_at == ^inserted_at and l.id <= ^id)
      )
      |> order_by([l], desc: l.inserted_at, desc: l.id)
      |> limit(^half)
      |> Repo.all()
      |> Enum.reverse()

    # Get logs after target (excluding target), ascending
    after_logs =
      Log
      |> where(
        [l],
        l.inserted_at > ^inserted_at or (l.inserted_at == ^inserted_at and l.id > ^id)
      )
      |> order_by([l], asc: l.inserted_at, asc: l.id)
      |> limit(^half)
      |> Repo.all()

    before_logs ++ after_logs
  end

  @doc """
  Checks if logs exist before the given cursor.
  """
  def has_logs_before?({inserted_at, id}, opts \\ []) do
    Log
    |> where([l], l.inserted_at < ^inserted_at or (l.inserted_at == ^inserted_at and l.id < ^id))
    |> apply_filters(opts)
    |> limit(1)
    |> Repo.exists?()
  end

  @doc """
  Checks if logs exist after the given cursor.
  """
  def has_logs_after?({inserted_at, id}, opts \\ []) do
    Log
    |> where([l], l.inserted_at > ^inserted_at or (l.inserted_at == ^inserted_at and l.id > ^id))
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
  defp filter_time_range(query, from, nil), do: where(query, [l], l.inserted_at >= ^from)
  defp filter_time_range(query, nil, to), do: where(query, [l], l.inserted_at <= ^to)

  defp filter_time_range(query, from, to),
    do: where(query, [l], l.inserted_at >= ^from and l.inserted_at <= ^to)

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
        |> where([l], l.inserted_at >= ^cutoff)
        |> apply_search_tokens(tokens)
        |> Repo.aggregate(:count, :id)
    end
  end

  def count_matches(_, _), do: 0

  @doc "Returns 1h, 24h, and 7d observed-time counts in one query."
  def preview_counts(search_query) when is_binary(search_query) do
    now = DateTime.utc_now()
    hour = DateTime.add(now, -3600, :second)
    day = DateTime.add(now, -86_400, :second)
    week = DateTime.add(now, -604_800, :second)

    case SearchParser.parse(search_query) do
      {:ok, [_ | _] = tokens} ->
        {hour_count, day_count, week_count} =
          Log
          |> where([l], l.inserted_at >= ^week)
          |> apply_search_tokens(tokens)
          |> select([l], {
            fragment("SUM(CASE WHEN ? >= ? THEN 1 ELSE 0 END)", l.inserted_at, ^hour),
            fragment("SUM(CASE WHEN ? >= ? THEN 1 ELSE 0 END)", l.inserted_at, ^day),
            count(l.id)
          })
          |> Repo.one(timeout: WhisperLogs.Config.alert_limits().query_timeout_ms)

        %{hour: hour_count || 0, day: day_count || 0, week: week_count || 0}

      _ ->
        %{hour: 0, day: 0, week: 0}
    end
  end

  @doc """
  Returns the current maximum observed-time cursor, or `{nil, nil}` when empty.
  """
  def max_observed_cursor do
    Log
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> select([l], {l.inserted_at, l.id})
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> {nil, nil}
      cursor -> cursor
    end
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

  # Regex pattern: match message OR metadata against regex
  defp apply_search_token({:regex, pattern}, query) do
    where(query, ^DbAdapter.text_regex_search(pattern))
  end

  # Exclude regex: NOT in message AND NOT in metadata
  defp apply_search_token({:exclude_regex, pattern}, query) do
    where(query, ^DbAdapter.text_regex_exclude(pattern))
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
    alias WhisperLogs.Accounts.Source

    Source
    |> where([s], is_nil(s.revoked_at))
    |> select([s], s.source)
    |> distinct(true)
    |> order_by([s], asc: s.source)
    |> Repo.all()
  end

  @doc """
  Returns the total count of logs in the database.
  """
  def count_logs do
    Repo.aggregate(Log, :count, :id)
  end

  @doc """
  Returns the observed timestamp of the oldest log in the database.
  Returns nil if no logs exist.
  """
  def oldest_log_timestamp do
    Repo.aggregate(Log, :min, :inserted_at)
  end

  @doc """
  Returns hourly log volume for the past N hours.
  Returns list of `{datetime, count, bytes}` tuples.
  """
  def volume_by_hour(hours \\ 48) do
    VolumeRollups.list("hour", hours)
  end

  @doc """
  Returns daily log volume for the past N days.
  Returns list of `{datetime, count, bytes}` tuples.
  """
  def volume_by_day(days \\ 30) do
    VolumeRollups.list("day", days)
  end

  @doc """
  Returns monthly log volume for the past N months.
  Returns list of `{datetime, count, bytes}` tuples.
  """
  def volume_by_month(months \\ 12) do
    days = VolumeRollups.list("day", months * 31)

    days
    |> Enum.group_by(fn {datetime, _, _} -> {datetime.year, datetime.month} end)
    |> Enum.map(fn {{year, month}, rows} ->
      bucket = DateTime.new!(Date.new!(year, month, 1), ~T[00:00:00], "Etc/UTC")
      count = Enum.sum(Enum.map(rows, fn {_, value, _} -> value end))
      bytes = Enum.sum(Enum.map(rows, fn {_, _, value} -> value end))
      {bucket, count, bytes}
    end)
    |> Enum.sort_by(fn {datetime, _, _} -> DateTime.to_unix(datetime) end)
  end

  @doc """
  Returns total volume from the past N hours for projection calculations.
  Returns `{count, bytes}` tuple.
  """
  def volume_last_n_hours(hours) do
    VolumeRollups.list("hour", hours)
    |> Enum.reduce({0, 0}, fn {_, count, bytes}, {count_total, byte_total} ->
      {count_total + count, byte_total + bytes}
    end)
  end

  def total_volume, do: VolumeRollups.totals()

  @doc """
  Deletes logs older than the given datetime.

  Returns `{count, nil}` where count is the number of deleted logs.
  """
  def delete_before(%DateTime{} = cutoff) do
    {:ok, result} =
      Repo.transaction(fn ->
        result = Log |> where([l], l.inserted_at < ^cutoff) |> Repo.delete_all()
        VolumeRollups.reconcile_after_delete!(cutoff)
        result
      end)

    result
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

  defp parse_numeric(value) when is_binary(value) do
    if byte_size(value) <= 128 and
         Regex.match?(~r/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/, value) do
      case Decimal.parse(value) do
        {decimal, ""} ->
          num = if DbAdapter.sqlite?(), do: Decimal.to_float(decimal), else: decimal
          {:ok, num}

        _error ->
          :error
      end
    else
      :error
    end
  end

  defp parse_numeric(_), do: :error

  # === Saved Searches ===

  def list_saved_searches(%User{id: user_id}) do
    SavedSearch
    |> where([s], s.user_id == ^user_id)
    |> order_by([s], asc: s.name)
    |> Repo.all()
    |> Enum.map(&deserialize_levels/1)
  end

  def get_saved_search(%User{id: user_id}, id) do
    SavedSearch
    |> where([s], s.user_id == ^user_id and s.id == ^id)
    |> Repo.one()
    |> case do
      nil -> nil
      saved_search -> deserialize_levels(saved_search)
    end
  end

  def create_saved_search(%User{id: user_id}, attrs) do
    attrs = serialize_levels(attrs)

    %SavedSearch{user_id: user_id}
    |> SavedSearch.changeset(attrs)
    |> Repo.insert()
  end

  def delete_saved_search(%SavedSearch{} = saved_search) do
    Repo.delete(saved_search)
  end

  defp serialize_levels(%{levels: levels} = attrs) when is_list(levels) do
    Map.put(attrs, :levels, Enum.join(levels, ","))
  end

  defp serialize_levels(%{"levels" => levels} = attrs) when is_list(levels) do
    Map.put(attrs, "levels", Enum.join(levels, ","))
  end

  defp serialize_levels(attrs), do: attrs

  defp deserialize_levels(%SavedSearch{levels: levels} = saved_search) when is_binary(levels) do
    %{saved_search | levels: String.split(levels, ",", trim: true)}
  end

  defp deserialize_levels(saved_search), do: saved_search
end
