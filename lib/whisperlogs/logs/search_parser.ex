defmodule WhisperLogs.Logs.SearchParser do
  @moduledoc """
  Parses search query strings into structured tokens for log filtering.

  Supports:
  - Plain terms: `error` - search message and all metadata values
  - Metadata filters: `user_id:123` - filter by specific metadata key
  - Numeric comparisons: `duration_ms:>100` - compare numeric metadata values
  - Negative terms: `-oban` - exclude matches
  - Negative metadata: `-level:debug` - exclude specific metadata key-value
  - Quoted phrases: `"error in module"` - exact phrase match
  - Combined: `error user_id:123 -debug` - multiple conditions (AND logic)

  Special pseudo-metadata keys (filter on schema fields, not metadata JSONB):
  - `level:error` - filter by log level (accepts aliases: debug/dbg, info/inf, warning/warn, error/err)
  - `timestamp:>2025-08-12` - filter by timestamp with comparison operators
  - `source:prod` - filter by source (ILIKE pattern match)
  """

  @type operator :: :eq | :gt | :gte | :lt | :lte

  @type token ::
          {:term, String.t()}
          | {:phrase, String.t()}
          | {:exclude, String.t()}
          | {:metadata, String.t(), operator(), String.t()}
          | {:exclude_metadata, String.t(), operator(), String.t()}
          # Pseudo-metadata tokens for schema fields
          | {:level_filter, String.t()}
          | {:exclude_level_filter, String.t()}
          | {:timestamp_filter, operator(), DateTime.t()}
          | {:exclude_timestamp_filter, operator(), DateTime.t()}
          | {:source_filter, String.t()}
          | {:exclude_source_filter, String.t()}

  # Level name normalization - maps various spellings to canonical level names
  @level_aliases %{
    "debug" => "debug",
    "dbg" => "debug",
    "info" => "info",
    "inf" => "info",
    "warning" => "warning",
    "warn" => "warning",
    "wrn" => "warning",
    "error" => "error",
    "err" => "error"
  }

  @type parse_result :: {:ok, [token()]} | {:error, String.t()}

  @doc """
  Parses a search query string into a list of tokens.

  ## Examples

      iex> SearchParser.parse("error user_id:123 -debug")
      {:ok, [
        {:term, "error"},
        {:metadata, "user_id", :eq, "123"},
        {:exclude, "debug"}
      ]}

      iex> SearchParser.parse("duration_ms:>100")
      {:ok, [{:metadata, "duration_ms", :gt, "100"}]}

      iex> SearchParser.parse("")
      {:ok, []}
  """
  @spec parse(String.t() | nil) :: parse_result()
  def parse(nil), do: {:ok, []}
  def parse(""), do: {:ok, []}

  def parse(query) when is_binary(query) do
    query
    |> String.trim()
    |> tokenize()
    |> classify_tokens()
  end

  defp tokenize(query) do
    # Match: quoted strings with optional -key: prefix, key:op:value pairs, or plain words
    # Order matters - more specific patterns first
    # Added support for comparison operators: >=, <=, >, <
    regex = ~r/
      -[\w.-]+:"[^"]*"          |  # -key:"quoted value"
      [\w.-]+:"[^"]*"           |  # key:"quoted value"
      "[^"]*"                   |  # "quoted phrase"
      -[\w.-]+:>=[\w.-]+        |  # -key:>=value
      -[\w.-]+:<=[\w.-]+        |  # -key:<=value
      -[\w.-]+:>[\w.-]+         |  # -key:>value
      -[\w.-]+:<[\w.-]+         |  # -key:<value
      [\w.-]+:>=[\w.-]+         |  # key:>=value
      [\w.-]+:<=[\w.-]+         |  # key:<=value
      [\w.-]+:>[\w.-]+          |  # key:>value
      [\w.-]+:<[\w.-]+          |  # key:<value
      -[\w.-]+:[\w.-]+          |  # -key:value
      [\w.-]+:[\w.-]+           |  # key:value
      -[\w.-]+                  |  # -term
      [\w.-]+                      # plain term
    /xu

    Regex.scan(regex, query)
    |> Enum.map(fn [match | _] -> match end)
  end

  defp classify_tokens(tokens) do
    result =
      tokens
      |> Enum.map(&classify_token/1)
      |> Enum.reject(&is_nil/1)

    {:ok, result}
  end

  defp classify_token(token) do
    cond do
      # Negative metadata filter with quoted value: -key:"value"
      Regex.match?(~r/^-[\w.-]+:"[^"]*"$/, token) ->
        parse_metadata_token(String.slice(token, 1..-1//1), :exclude_metadata)

      # Metadata filter with quoted value: key:"value"
      Regex.match?(~r/^[\w.-]+:"[^"]*"$/, token) ->
        parse_metadata_token(token, :metadata)

      # Quoted phrase: "value"
      String.starts_with?(token, "\"") and String.ends_with?(token, "\"") ->
        value = unquote_value(token)
        if value != "", do: {:phrase, value}, else: nil

      # Negative metadata filter with operator: -key:>=value, -key:>value, etc.
      Regex.match?(~r/^-[\w.-]+:(?:>=|<=|>|<)[\w.-]+$/, token) ->
        parse_metadata_token(String.slice(token, 1..-1//1), :exclude_metadata)

      # Metadata filter with operator: key:>=value, key:>value, etc.
      Regex.match?(~r/^[\w.-]+:(?:>=|<=|>|<)[\w.-]+$/, token) ->
        parse_metadata_token(token, :metadata)

      # Negative metadata filter: -key:value
      Regex.match?(~r/^-[\w.-]+:[\w.-]+$/, token) ->
        parse_metadata_token(String.slice(token, 1..-1//1), :exclude_metadata)

      # Metadata filter: key:value
      Regex.match?(~r/^[\w.-]+:[\w.-]+$/, token) ->
        parse_metadata_token(token, :metadata)

      # Negative term: -word
      String.starts_with?(token, "-") ->
        term = String.slice(token, 1..-1//1)
        if term != "", do: {:exclude, term}, else: nil

      # Plain term
      true ->
        if token != "", do: {:term, token}, else: nil
    end
  end

  defp parse_metadata_token(token, type) do
    case String.split(token, ":", parts: 2) do
      [key, value_with_op] when key != "" ->
        {operator, value} = extract_operator(value_with_op)
        key_lower = String.downcase(key)

        # Check for pseudo-keys (level, timestamp, source) that filter schema fields
        cond do
          key_lower == "level" ->
            parse_level_filter(value, type)

          key_lower == "timestamp" ->
            parse_timestamp_filter(operator, value, type)

          key_lower == "source" ->
            parse_source_filter(value, type)

          true ->
            # Regular metadata token
            {type, key, operator, unquote_value(value)}
        end

      _ ->
        nil
    end
  end

  # Parse level filter with alias normalization
  defp parse_level_filter(value, type) do
    value_lower = String.downcase(unquote_value(value))

    case Map.get(@level_aliases, value_lower) do
      nil ->
        # Unknown level - skip this token
        nil

      normalized_level ->
        case type do
          :metadata -> {:level_filter, normalized_level}
          :exclude_metadata -> {:exclude_level_filter, normalized_level}
        end
    end
  end

  # Parse timestamp filter with datetime parsing
  defp parse_timestamp_filter(operator, value, type) do
    case parse_datetime_value(unquote_value(value)) do
      {:ok, datetime} ->
        case type do
          :metadata -> {:timestamp_filter, operator, datetime}
          :exclude_metadata -> {:exclude_timestamp_filter, operator, datetime}
        end

      :error ->
        # Invalid timestamp - skip this token
        nil
    end
  end

  # Parse source filter (simple ILIKE pattern)
  defp parse_source_filter(value, type) do
    case type do
      :metadata -> {:source_filter, unquote_value(value)}
      :exclude_metadata -> {:exclude_source_filter, unquote_value(value)}
    end
  end

  # Parse datetime values - supports relative dates and absolute formats
  defp parse_datetime_value(value) do
    value_lower = String.downcase(value)

    cond do
      value_lower == "today" ->
        {:ok, start_of_day(DateTime.utc_now())}

      value_lower == "yesterday" ->
        {:ok, start_of_day(DateTime.add(DateTime.utc_now(), -1, :day))}

      Regex.match?(~r/^-\d+(m|h|d|w)$/, value_lower) ->
        parse_relative_offset(value_lower)

      true ->
        # Use date_time_parser for all other formats (ISO 8601, natural language, etc.)
        parse_absolute_datetime(value)
    end
  end

  defp start_of_day(dt) do
    dt
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp parse_relative_offset("-" <> rest) do
    case Regex.run(~r/^(\d+)(m|h|d|w)$/, rest) do
      [_, amount_str, "m"] ->
        amount = String.to_integer(amount_str)
        {:ok, DateTime.add(DateTime.utc_now(), -amount, :minute)}

      [_, amount_str, "h"] ->
        amount = String.to_integer(amount_str)
        {:ok, DateTime.add(DateTime.utc_now(), -amount, :hour)}

      [_, amount_str, "d"] ->
        amount = String.to_integer(amount_str)
        {:ok, DateTime.add(DateTime.utc_now(), -amount, :day)}

      [_, amount_str, "w"] ->
        amount = String.to_integer(amount_str) * 7
        {:ok, DateTime.add(DateTime.utc_now(), -amount, :day)}

      _ ->
        :error
    end
  end

  defp parse_absolute_datetime(value) do
    # First try ISO 8601 date format (YYYY-MM-DD)
    case Date.from_iso8601(value) do
      {:ok, date} ->
        {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}

      _ ->
        # Try ISO 8601 datetime
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} ->
            {:ok, dt}

          _ ->
            # Fall back to date_time_parser for flexible formats
            case DateTimeParser.parse_datetime(value) do
              {:ok, datetime} ->
                # Ensure we have a DateTime (not NaiveDateTime)
                case datetime do
                  %DateTime{} = dt -> {:ok, dt}
                  %NaiveDateTime{} = ndt -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
                end

              _ ->
                :error
            end
        end
    end
  end

  defp extract_operator(value) do
    cond do
      String.starts_with?(value, ">=") -> {:gte, String.slice(value, 2..-1//1)}
      String.starts_with?(value, "<=") -> {:lte, String.slice(value, 2..-1//1)}
      String.starts_with?(value, ">") -> {:gt, String.slice(value, 1..-1//1)}
      String.starts_with?(value, "<") -> {:lt, String.slice(value, 1..-1//1)}
      true -> {:eq, value}
    end
  end

  defp unquote_value(value) do
    value
    |> String.trim()
    |> String.trim("\"")
    |> String.replace(~r/\\"/, "\"")
  end

  @doc """
  Escapes special LIKE/ILIKE pattern characters and wraps with wildcards.

  ## Examples

      iex> SearchParser.escape_like("error")
      "%error%"

      iex> SearchParser.escape_like("100%")
      "%100\\%%"
  """
  @spec escape_like(String.t()) :: String.t()
  def escape_like(term) do
    escaped =
      term
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%#{escaped}%"
  end
end
