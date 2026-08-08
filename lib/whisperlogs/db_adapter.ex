defmodule WhisperLogs.DbAdapter do
  @moduledoc """
  Provides database-agnostic helpers for SQLite and PostgreSQL compatibility.

  This module detects the configured database adapter at runtime and provides
  helper functions for building adapter-specific queries using Ecto's `dynamic()`.

  The adapter is determined by the `:db_adapter` config set in `runtime.exs`
  based on whether `DATABASE_URL` is present.

  ## Query Helpers

  Use these in Ecto queries with the `^` operator to interpolate dynamic expressions:

      where(query, ^DbAdapter.text_search(pattern))
      where(query, ^DbAdapter.level_eq(level))
      group_by([l], ^DbAdapter.trunc_hour())
  """

  import Ecto.Query

  @doc """
  Returns true if using SQLite adapter.
  """
  def sqlite? do
    Application.get_env(:whisperlogs, :db_adapter, :sqlite) == :sqlite
  end

  @doc """
  Returns true if using PostgreSQL adapter.
  """
  def postgres? do
    Application.get_env(:whisperlogs, :db_adapter, :sqlite) == :postgres
  end

  @serialized_namespaces %{alerts: 1_019_001, exports: 1_019_002, syslog_sources: 1_019_003}

  @doc """
  Runs a count-and-mutate operation under one adapter-specific namespace lock.

  PostgreSQL uses a transaction-scoped advisory lock. SQLite starts an immediate
  transaction so the writer reservation is acquired before the quota read.
  """
  def serialized_transaction(namespace, fun)
      when is_map_key(@serialized_namespaces, namespace) and is_function(fun, 0) do
    if sqlite?() do
      WhisperLogs.Repo.transaction(fun, mode: :immediate)
    else
      WhisperLogs.Repo.transaction(fn ->
        lock = Map.fetch!(@serialized_namespaces, namespace)
        WhisperLogs.Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock])
        fun.()
      end)
    end
  end

  # ===========================================================================
  # Composite Query Helpers (for common patterns in logs.ex)
  # ===========================================================================

  @doc """
  Text search in message OR metadata.
  Returns a dynamic that matches if pattern is found in either field.
  """
  def text_search(pattern) do
    if sqlite?() do
      dynamic(
        [l],
        fragment("? LIKE ? ESCAPE '\\'", l.message, ^pattern) or
          fragment("json(?) LIKE ? ESCAPE '\\'", l.metadata, ^pattern)
      )
    else
      dynamic([l], ilike(l.message, ^pattern) or ilike(fragment("?::text", l.metadata), ^pattern))
    end
  end

  @doc """
  Regex search in message OR metadata.
  Returns a dynamic that matches if regex pattern is found in either field.
  """
  def text_regex_search(pattern) do
    if sqlite?() do
      # Prepend (?i) for case-insensitive PCRE2 matching in SQLean
      ci_pattern = "(?i)" <> pattern

      dynamic(
        [l],
        fragment("? REGEXP ?", l.message, ^ci_pattern) or
          fragment("json(?) REGEXP ?", l.metadata, ^ci_pattern)
      )
    else
      dynamic(
        [l],
        fragment("? ~* ?", l.message, ^pattern) or
          fragment("?::text ~* ?", l.metadata, ^pattern)
      )
    end
  end

  @doc """
  Exclude regex search - matches if regex pattern is NOT found in message AND metadata.
  """
  def text_regex_exclude(pattern) do
    if sqlite?() do
      ci_pattern = "(?i)" <> pattern

      dynamic(
        [l],
        fragment("NOT (? REGEXP ?)", l.message, ^ci_pattern) and
          fragment("NOT (json(?) REGEXP ?)", l.metadata, ^ci_pattern)
      )
    else
      dynamic(
        [l],
        fragment("? !~* ?", l.message, ^pattern) and
          fragment("?::text !~* ?", l.metadata, ^pattern)
      )
    end
  end

  @doc """
  Exclude text search - matches if pattern is NOT found in message AND metadata.
  """
  def text_exclude(pattern) do
    if sqlite?() do
      dynamic(
        [l],
        fragment("? NOT LIKE ? ESCAPE '\\'", l.message, ^pattern) and
          fragment("json(?) NOT LIKE ? ESCAPE '\\'", l.metadata, ^pattern)
      )
    else
      dynamic(
        [l],
        not ilike(l.message, ^pattern) and not ilike(fragment("?::text", l.metadata), ^pattern)
      )
    end
  end

  @doc """
  Level equality - matches level field OR metadata.level.
  """
  def level_eq(level) do
    if sqlite?() do
      dynamic(
        [l],
        l.level == ^level or fragment("json_extract(?, ?)", l.metadata, "$.level") == ^level
      )
    else
      dynamic([l], l.level == ^level or fragment("?->>?", l.metadata, "level") == ^level)
    end
  end

  @doc """
  Level exclusion - matches if level field != value AND metadata.level is null or != value.
  """
  def level_neq(level) do
    if sqlite?() do
      dynamic(
        [l],
        l.level != ^level and
          (fragment("json_extract(?, ?) IS NULL", l.metadata, "$.level") or
             fragment("json_extract(?, ?)", l.metadata, "$.level") != ^level)
      )
    else
      dynamic(
        [l],
        l.level != ^level and
          (fragment("?->>? IS NULL", l.metadata, "level") or
             fragment("?->>?", l.metadata, "level") != ^level)
      )
    end
  end

  @doc """
  Source match - matches source field OR metadata.source with ILIKE pattern.
  """
  def source_match(pattern) do
    if sqlite?() do
      dynamic(
        [l],
        fragment("? LIKE ? ESCAPE '\\'", l.source, ^pattern) or
          fragment("json_extract(?, '$.source') LIKE ? ESCAPE '\\'", l.metadata, ^pattern)
      )
    else
      dynamic(
        [l],
        ilike(l.source, ^pattern) or ilike(fragment("?->>?", l.metadata, "source"), ^pattern)
      )
    end
  end

  @doc """
  Source exclusion - matches if source field doesn't match AND metadata.source is null or doesn't match.
  """
  def source_exclude(pattern) do
    if sqlite?() do
      dynamic(
        [l],
        fragment("? NOT LIKE ? ESCAPE '\\'", l.source, ^pattern) and
          (fragment("json_extract(?, '$.source') IS NULL", l.metadata) or
             fragment("json_extract(?, '$.source') NOT LIKE ? ESCAPE '\\'", l.metadata, ^pattern))
      )
    else
      dynamic(
        [l],
        not ilike(l.source, ^pattern) and
          (fragment("?->>? IS NULL", l.metadata, "source") or
             not ilike(fragment("?->>?", l.metadata, "source"), ^pattern))
      )
    end
  end

  @doc """
  Request ID equality - matches metadata.request_id.
  """
  def request_id_eq(request_id) do
    if sqlite?() do
      dynamic([l], fragment("json_extract(?, ?)", l.metadata, "$.request_id") == ^request_id)
    else
      dynamic([l], fragment("?->>?", l.metadata, "request_id") == ^request_id)
    end
  end

  # ===========================================================================
  # Timestamp Truncation (for group_by / select / order_by)
  # ===========================================================================

  @doc """
  Truncate timestamp to hour.
  Returns a dynamic for use in group_by, select, order_by.
  """
  def trunc_hour do
    if sqlite?() do
      dynamic(
        [l],
        type(fragment("strftime('%Y-%m-%dT%H:00:00Z', ?)", l.inserted_at), :utc_datetime)
      )
    else
      dynamic([l], fragment("date_trunc('hour', ?)", l.inserted_at))
    end
  end

  @doc """
  Truncate timestamp to day.
  Returns a dynamic for use in group_by, select, order_by.
  """
  def trunc_day do
    if sqlite?() do
      dynamic(
        [l],
        type(fragment("strftime('%Y-%m-%dT00:00:00Z', ?)", l.inserted_at), :utc_datetime)
      )
    else
      dynamic([l], fragment("date_trunc('day', ?)", l.inserted_at))
    end
  end

  @doc """
  Truncate timestamp to month (first day of month).
  Returns a dynamic for use in group_by, select, order_by.
  """
  def trunc_month do
    if sqlite?() do
      dynamic(
        [l],
        type(fragment("strftime('%Y-%m-01T00:00:00Z', ?)", l.inserted_at), :utc_datetime)
      )
    else
      dynamic([l], fragment("date_trunc('month', ?)", l.inserted_at))
    end
  end

  @doc """
  Calculates byte size of message + metadata for volume stats.
  Returns a dynamic for use in select with sum().
  """
  def log_byte_size do
    if sqlite?() do
      dynamic([l], fragment("length(?) + length(coalesce(json(?), '{}'))", l.message, l.metadata))
    else
      dynamic(
        [l],
        fragment("octet_length(?) + octet_length(coalesce(?::text, '{}'))", l.message, l.metadata)
      )
    end
  end

  @doc """
  Returns complete volume select as a single dynamic for hourly aggregation.
  Must be interpolated at top level: `select([l], ^volume_select_hour())`
  Returns %{timestamp, count, bytes} map.
  """
  def volume_select_hour do
    if sqlite?() do
      dynamic([l], %{
        timestamp:
          type(fragment("strftime('%Y-%m-%dT%H:00:00Z', ?)", l.inserted_at), :utc_datetime),
        count: count(l.id),
        bytes: sum(fragment("length(?) + length(coalesce(json(?), '{}'))", l.message, l.metadata))
      })
    else
      dynamic([l], %{
        timestamp: fragment("date_trunc('hour', ?)", l.inserted_at),
        count: count(l.id),
        bytes:
          sum(
            fragment(
              "octet_length(?) + octet_length(coalesce(?::text, '{}'))",
              l.message,
              l.metadata
            )
          )
      })
    end
  end

  @doc """
  Returns complete volume select as a single dynamic for daily aggregation.
  """
  def volume_select_day do
    if sqlite?() do
      dynamic([l], %{
        timestamp:
          type(fragment("strftime('%Y-%m-%dT00:00:00Z', ?)", l.inserted_at), :utc_datetime),
        count: count(l.id),
        bytes: sum(fragment("length(?) + length(coalesce(json(?), '{}'))", l.message, l.metadata))
      })
    else
      dynamic([l], %{
        timestamp: fragment("date_trunc('day', ?)", l.inserted_at),
        count: count(l.id),
        bytes:
          sum(
            fragment(
              "octet_length(?) + octet_length(coalesce(?::text, '{}'))",
              l.message,
              l.metadata
            )
          )
      })
    end
  end

  @doc """
  Returns complete volume select as a single dynamic for monthly aggregation.
  """
  def volume_select_month do
    if sqlite?() do
      dynamic([l], %{
        timestamp:
          type(fragment("strftime('%Y-%m-01T00:00:00Z', ?)", l.inserted_at), :utc_datetime),
        count: count(l.id),
        bytes: sum(fragment("length(?) + length(coalesce(json(?), '{}'))", l.message, l.metadata))
      })
    else
      dynamic([l], %{
        timestamp: fragment("date_trunc('month', ?)", l.inserted_at),
        count: count(l.id),
        bytes:
          sum(
            fragment(
              "octet_length(?) + octet_length(coalesce(?::text, '{}'))",
              l.message,
              l.metadata
            )
          )
      })
    end
  end

  @doc """
  Returns complete volume select as a single dynamic for total aggregation.
  Returns %{count, bytes} map.
  """
  def volume_select_total do
    if sqlite?() do
      dynamic([l], %{
        count: count(l.id),
        bytes: sum(fragment("length(?) + length(coalesce(json(?), '{}'))", l.message, l.metadata))
      })
    else
      dynamic([l], %{
        count: count(l.id),
        bytes:
          sum(
            fragment(
              "octet_length(?) + octet_length(coalesce(?::text, '{}'))",
              l.message,
              l.metadata
            )
          )
      })
    end
  end

  # ===========================================================================
  # JSON Field Helpers (for runtime key access)
  # ===========================================================================

  @doc """
  JSON value extraction for runtime key.
  Returns a dynamic that extracts a value from a JSON field.
  """
  def json_extract_fragment(field_name, key) when is_atom(field_name) do
    if sqlite?() do
      dynamic([l], fragment("json_extract(?, ?)", field(l, ^field_name), ^"$.#{key}"))
    else
      dynamic([l], fragment("?->>?", field(l, ^field_name), ^key))
    end
  end

  @doc """
  Case-insensitive LIKE on a JSON extracted value (runtime key).
  """
  def json_ilike_fragment(field_name, key, pattern) when is_atom(field_name) do
    json_path = "$.#{key}"

    if sqlite?() do
      dynamic(
        [l],
        fragment(
          "json_extract(?, ?) LIKE ? ESCAPE '\\'",
          field(l, ^field_name),
          ^json_path,
          ^pattern
        )
      )
    else
      dynamic([l], ilike(fragment("?->>?", field(l, ^field_name), ^key), ^pattern))
    end
  end

  @doc """
  JSON numeric comparison (runtime key and operator).
  Operators: :gt, :gte, :lt, :lte
  """
  # Keep string-number semantics identical on SQLite REAL and PostgreSQL numeric.
  # Canonical decimal strings use ordinary decimal notation; producers that need
  # scientific notation can send a native JSON number. This prevents SQLite
  # infinities and PostgreSQL numeric overflows before either adapter casts.
  @canonical_decimal_pattern "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?$"

  def json_numeric_compare(field_name, key, op, num) when is_atom(field_name) and is_atom(op) do
    json_path = "$.#{key}"

    if sqlite?() do
      sqlite_numeric_compare(field_name, json_path, op, num)
    else
      postgres_numeric_compare(field_name, key, op, num)
    end
  end

  defp sqlite_numeric_compare(field_name, path, :gt, num) do
    dynamic(
      [l],
      fragment(
        "(CASE WHEN json_type(?, ?) IN ('integer','real') THEN CAST(json_extract(?, ?) AS REAL) WHEN json_type(?, ?) = 'text' AND length(json_extract(?, ?)) <= 128 AND json_extract(?, ?) REGEXP ? THEN CAST(json_extract(?, ?) AS REAL) END) > ?",
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        ^@canonical_decimal_pattern,
        field(l, ^field_name),
        ^path,
        ^num
      )
    )
  end

  defp sqlite_numeric_compare(field_name, path, :gte, num) do
    dynamic(
      [l],
      fragment(
        "(CASE WHEN json_type(?, ?) IN ('integer','real') THEN CAST(json_extract(?, ?) AS REAL) WHEN json_type(?, ?) = 'text' AND length(json_extract(?, ?)) <= 128 AND json_extract(?, ?) REGEXP ? THEN CAST(json_extract(?, ?) AS REAL) END) >= ?",
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        ^@canonical_decimal_pattern,
        field(l, ^field_name),
        ^path,
        ^num
      )
    )
  end

  defp sqlite_numeric_compare(field_name, path, :lt, num) do
    dynamic(
      [l],
      fragment(
        "(CASE WHEN json_type(?, ?) IN ('integer','real') THEN CAST(json_extract(?, ?) AS REAL) WHEN json_type(?, ?) = 'text' AND length(json_extract(?, ?)) <= 128 AND json_extract(?, ?) REGEXP ? THEN CAST(json_extract(?, ?) AS REAL) END) < ?",
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        ^@canonical_decimal_pattern,
        field(l, ^field_name),
        ^path,
        ^num
      )
    )
  end

  defp sqlite_numeric_compare(field_name, path, :lte, num) do
    dynamic(
      [l],
      fragment(
        "(CASE WHEN json_type(?, ?) IN ('integer','real') THEN CAST(json_extract(?, ?) AS REAL) WHEN json_type(?, ?) = 'text' AND length(json_extract(?, ?)) <= 128 AND json_extract(?, ?) REGEXP ? THEN CAST(json_extract(?, ?) AS REAL) END) <= ?",
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        field(l, ^field_name),
        ^path,
        ^@canonical_decimal_pattern,
        field(l, ^field_name),
        ^path,
        ^num
      )
    )
  end

  defp postgres_numeric_compare(field_name, key, :gt, num) do
    dynamic(
      [l],
      fragment(
        "(CASE WHEN jsonb_typeof(?->?) = 'number' THEN (?->>?)::numeric WHEN jsonb_typeof(?->?) = 'string' AND octet_length(?->>?) <= 128 AND (?->>?) ~ ? AND pg_input_is_valid(?->>?, 'numeric') THEN (?->>?)::numeric END) > ?",
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        ^@canonical_decimal_pattern,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        ^num
      )
    )
  end

  defp postgres_numeric_compare(field_name, key, :gte, num) do
    dynamic(
      [l],
      fragment(
        "(CASE WHEN jsonb_typeof(?->?) = 'number' THEN (?->>?)::numeric WHEN jsonb_typeof(?->?) = 'string' AND octet_length(?->>?) <= 128 AND (?->>?) ~ ? AND pg_input_is_valid(?->>?, 'numeric') THEN (?->>?)::numeric END) >= ?",
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        ^@canonical_decimal_pattern,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        ^num
      )
    )
  end

  defp postgres_numeric_compare(field_name, key, :lt, num) do
    dynamic(
      [l],
      fragment(
        "(CASE WHEN jsonb_typeof(?->?) = 'number' THEN (?->>?)::numeric WHEN jsonb_typeof(?->?) = 'string' AND octet_length(?->>?) <= 128 AND (?->>?) ~ ? AND pg_input_is_valid(?->>?, 'numeric') THEN (?->>?)::numeric END) < ?",
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        ^@canonical_decimal_pattern,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        ^num
      )
    )
  end

  defp postgres_numeric_compare(field_name, key, :lte, num) do
    dynamic(
      [l],
      fragment(
        "(CASE WHEN jsonb_typeof(?->?) = 'number' THEN (?->>?)::numeric WHEN jsonb_typeof(?->?) = 'string' AND octet_length(?->>?) <= 128 AND (?->>?) ~ ? AND pg_input_is_valid(?->>?, 'numeric') THEN (?->>?)::numeric END) <= ?",
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        ^@canonical_decimal_pattern,
        field(l, ^field_name),
        ^key,
        field(l, ^field_name),
        ^key,
        ^num
      )
    )
  end

  @doc """
  Negated JSON numeric comparison for exclude filters.
  Returns true if key is NULL OR the comparison is false.
  """
  def json_numeric_exclude(field_name, key, op, num) when is_atom(field_name) and is_atom(op) do
    # Negate the operator
    negated_op =
      case op do
        :gt -> :lte
        :gte -> :lt
        :lt -> :gte
        :lte -> :gt
      end

    json_numeric_compare(field_name, key, negated_op, num)
  end

  @doc """
  Check if JSON key is NULL (runtime key).
  """
  def json_is_null_fragment(field_name, key) when is_atom(field_name) do
    if sqlite?() do
      dynamic([l], fragment("json_extract(?, ?) IS NULL", field(l, ^field_name), ^"$.#{key}"))
    else
      dynamic([l], fragment("?->>? IS NULL", field(l, ^field_name), ^key))
    end
  end

  @doc """
  Exclude metadata ILIKE - matches if key is NULL or value doesn't match pattern.
  """
  def json_not_ilike_fragment(field_name, key, pattern) when is_atom(field_name) do
    json_path = "$.#{key}"

    if sqlite?() do
      dynamic(
        [l],
        fragment("json_extract(?, ?) IS NULL", field(l, ^field_name), ^json_path) or
          fragment(
            "json_extract(?, ?) NOT LIKE ? ESCAPE '\\'",
            field(l, ^field_name),
            ^json_path,
            ^pattern
          )
      )
    else
      dynamic(
        [l],
        fragment("?->>? IS NULL", field(l, ^field_name), ^key) or
          not ilike(fragment("?->>?", field(l, ^field_name), ^key), ^pattern)
      )
    end
  end

  # ===========================================================================
  # Utility Functions
  # ===========================================================================

  @doc """
  Returns the default SQLite database path.
  Uses XDG_DATA_HOME (defaults to ~/.local/share).
  """
  def default_db_path do
    System.get_env("DATABASE_PATH") ||
      Path.join(xdg_data_home(), "whisperlogs/db.sqlite")
  end

  defp xdg_data_home do
    System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share")
  end

  @doc """
  Ensures the directory for the SQLite database exists.
  """
  def ensure_db_directory! do
    path = default_db_path()
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> raise "Failed to create database directory #{dir}: #{inspect(reason)}"
    end
  end
end
