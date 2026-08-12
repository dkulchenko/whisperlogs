defmodule WhisperLogs.MCP do
  @moduledoc """
  Stateless MCP 2026-07-28 server implementation for log search.
  """

  alias WhisperLogs.Accounts.Scope
  alias WhisperLogs.Logs

  @protocol_version "2026-07-28"
  @cursor_salt "mcp-log-cursor-v1"
  @cursor_lifetime_seconds 86_400
  @tool_name "search_logs"

  def protocol_version, do: @protocol_version
  def tool_name, do: @tool_name

  def discover_result do
    %{
      "resultType" => "complete",
      "supportedVersions" => [@protocol_version],
      "capabilities" => %{"tools" => %{}},
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => %{
          "name" => "WhisperLogs",
          "version" => Application.spec(:whisperlogs, :vsn) |> to_string()
        }
      },
      "instructions" =>
        "Search the authenticated user's WhisperLogs workspace with search_logs. Prefer the structured since and until fields for time windows. Use query for terms and filters such as level:error, request_path:\"/checkout\", or timestamp:>=2026-08-12T00:15:00Z. Metadata keys may optionally use a metadata. prefix. Results are newest first; pass next_cursor unchanged to continue.",
      "ttlMs" => 300_000,
      "cacheScope" => "private"
    }
  end

  def tools_result do
    %{
      "resultType" => "complete",
      "tools" => [tool_definition()],
      "ttlMs" => 300_000,
      "cacheScope" => "private"
    }
  end

  def call(%Scope{} = scope, @tool_name, arguments) when is_map(arguments) do
    with {:ok, query} <- optional_query(arguments),
         {:ok, limit} <- optional_limit(arguments),
         {:ok, since} <- optional_datetime(arguments, "since"),
         {:ok, until} <- optional_datetime(arguments, "until"),
         :ok <- validate_time_range(since, until),
         :ok <- reject_unknown_arguments(arguments),
         identity = search_identity(query, since, until),
         {:ok, before} <- decode_cursor(Map.get(arguments, "cursor"), scope, identity),
         {:ok, page} <-
           Logs.search_logs(scope, query,
             limit: limit,
             before: before,
             since: since,
             until: until
           ) do
      {:ok, search_result(scope, identity, page)}
    else
      {:error, reason} -> {:ok, tool_error(reason)}
    end
  rescue
    DBConnection.ConnectionError -> {:ok, tool_error(:query_timeout)}
  end

  def call(%Scope{}, @tool_name, _arguments), do: {:ok, tool_error(:invalid_arguments)}
  def call(%Scope{}, _name, _arguments), do: {:error, :unknown_tool}

  defp tool_definition do
    %{
      "name" => @tool_name,
      "title" => "Search WhisperLogs",
      "description" =>
        "Search logs and return a newest-first page. Prefer since/until for RFC 3339 time windows. Query examples: `checkout`, `level:error stripe`, `request_path:\"/checkout\"`, `duration_ms:>100`, and `timestamp:>=2026-08-12T00:15:00Z`. Plain terms search messages and metadata; filters are ANDed. Metadata keys can be written as `request_path` or `metadata.request_path`. An empty or omitted query returns the newest logs.",
      "inputSchema" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "maxLength" => 4_096,
            "default" => "",
            "description" =>
              "Optional WhisperLogs query. Filters are ANDed. Use `level:error`, `request_path:\"/checkout\"`, or `timestamp:>=2026-08-12T00:15:00Z`; use an empty string for all logs."
          },
          "since" => %{
            "type" => "string",
            "format" => "date-time",
            "description" =>
              "Inclusive lower bound on the log's producer timestamp, as RFC 3339 (for example 2026-08-12T00:15:00Z). Prefer this over embedding a lower time bound in query."
          },
          "until" => %{
            "type" => "string",
            "format" => "date-time",
            "description" => "Exclusive upper bound on the log's producer timestamp, as RFC 3339."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 100,
            "default" => 50
          },
          "cursor" => %{
            "type" => "string",
            "description" => "Opaque next_cursor from the previous response."
          }
        },
        "additionalProperties" => false
      },
      "outputSchema" => output_schema(),
      "annotations" => %{
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      }
    }
  end

  defp output_schema do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "properties" => %{
        "logs" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "integer"},
              "timestamp" => %{"type" => "string", "format" => "date-time"},
              "observed_at" => %{"type" => "string", "format" => "date-time"},
              "level" => %{"type" => "string"},
              "source" => %{"type" => "string"},
              "message" => %{"type" => "string"},
              "metadata" => %{"type" => "object"}
            },
            "required" => ~w(id timestamp observed_at level source message metadata),
            "additionalProperties" => false
          }
        },
        "has_more" => %{"type" => "boolean"},
        "next_cursor" => %{"type" => ["string", "null"]}
      },
      "required" => ~w(logs has_more next_cursor),
      "additionalProperties" => false
    }
  end

  defp search_result(scope, identity, %{logs: logs, has_more: database_has_more}) do
    max_bytes = WhisperLogs.Config.mcp_limits().max_response_bytes

    {included, size_truncated?} = fit_logs(logs, max_bytes)
    has_more = database_has_more or size_truncated?

    next_cursor =
      case {has_more, List.last(included)} do
        {true, log} when not is_nil(log) -> encode_cursor(scope, identity, log)
        _ -> nil
      end

    structured = %{
      "logs" => Enum.map(included, &serialize_log/1),
      "has_more" => has_more,
      "next_cursor" => next_cursor
    }

    %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => Jason.encode!(structured)}],
      "structuredContent" => structured,
      "isError" => false
    }
  end

  defp fit_logs(logs, max_bytes) do
    Enum.reduce_while(logs, {[], false}, fn log, {included, _truncated?} ->
      candidate = included ++ [log]

      structured = %{
        "logs" => Enum.map(candidate, &serialize_log/1),
        "has_more" => true,
        "next_cursor" => nil
      }

      result = %{
        "resultType" => "complete",
        "content" => [%{"type" => "text", "text" => Jason.encode!(structured)}],
        "structuredContent" => structured,
        "isError" => false
      }

      if Jason.encode_to_iodata!(result) |> IO.iodata_length() <= max_bytes - 2_048 do
        {:cont, {candidate, false}}
      else
        {:halt, {included, true}}
      end
    end)
  end

  defp serialize_log(log) do
    %{
      "id" => log.id,
      "timestamp" => DateTime.to_iso8601(log.timestamp),
      "observed_at" => DateTime.to_iso8601(log.inserted_at),
      "level" => log.level,
      "source" => log.source,
      "message" => log.message,
      "metadata" => log.metadata || %{}
    }
  end

  defp encode_cursor(%Scope{user: user}, identity, log) do
    Phoenix.Token.encrypt(
      WhisperLogsWeb.Endpoint,
      @cursor_salt,
      %{
        "user_id" => user.id,
        "search" => identity,
        "observed_at" => DateTime.to_iso8601(log.inserted_at),
        "id" => log.id
      },
      max_age: @cursor_lifetime_seconds
    )
  end

  defp decode_cursor(nil, _scope, _query), do: {:ok, nil}
  defp decode_cursor("", _scope, _query), do: {:error, :invalid_cursor}

  defp decode_cursor(cursor, %Scope{user: user}, identity) when is_binary(cursor) do
    with {:ok, payload} <-
           Phoenix.Token.decrypt(WhisperLogsWeb.Endpoint, @cursor_salt, cursor,
             max_age: @cursor_lifetime_seconds
           ),
         %{
           "user_id" => user_id,
           "search" => ^identity,
           "observed_at" => observed_at,
           "id" => id
         } <- payload,
         true <- user_id == user.id and is_integer(id),
         {:ok, datetime, 0} <- DateTime.from_iso8601(observed_at) do
      {:ok, {datetime, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_cursor, _scope, _query), do: {:error, :invalid_cursor}

  defp optional_query(arguments) do
    case Map.get(arguments, "query", "") do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, :invalid_arguments}
    end
  end

  defp optional_datetime(arguments, key) do
    case Map.get(arguments, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
          _ -> {:error, :invalid_datetime}
        end

      _ ->
        {:error, :invalid_datetime}
    end
  end

  defp validate_time_range(nil, nil), do: :ok
  defp validate_time_range(%DateTime{}, nil), do: :ok
  defp validate_time_range(nil, %DateTime{}), do: :ok

  defp validate_time_range(%DateTime{} = since, %DateTime{} = until) do
    if DateTime.compare(since, until) == :lt, do: :ok, else: {:error, :invalid_time_range}
  end

  defp search_identity(query, since, until) do
    %{
      "query" => query,
      "since" => encode_datetime(since),
      "until" => encode_datetime(until)
    }
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp optional_limit(arguments) do
    case Map.get(arguments, "limit", 50) do
      limit when is_integer(limit) and limit in 1..100 -> {:ok, limit}
      _ -> {:error, :invalid_limit}
    end
  end

  defp reject_unknown_arguments(arguments) do
    if Enum.all?(Map.keys(arguments), &(&1 in ~w(query since until limit cursor))),
      do: :ok,
      else: {:error, :invalid_arguments}
  end

  defp tool_error(reason) do
    message =
      case reason do
        :invalid_query -> "The query does not contain a valid WhisperLogs search expression."
        :query_too_large -> "The query exceeds the configured size limit."
        :invalid_limit -> "limit must be an integer from 1 through 100."
        :invalid_cursor -> "The cursor is invalid, expired, or belongs to another search."
        :query_timeout -> "The log search timed out. Narrow the query and try again."
        :invalid_datetime -> "since and until must be RFC 3339 timestamps."
        :invalid_time_range -> "since must be earlier than until."
        _ -> "Invalid search_logs arguments."
      end

    %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => message}],
      "isError" => true
    }
  end
end
