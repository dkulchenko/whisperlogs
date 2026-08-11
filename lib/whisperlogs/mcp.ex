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
        "Search the authenticated user's WhisperLogs workspace with search_logs. Use an empty query for newest logs; otherwise use the WhisperLogs grammar (terms, phrases, exclusions, regex, metadata comparisons, level:, source:, and timestamp:). Results are newest first; pass next_cursor unchanged to continue.",
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
    with {:ok, query} <- required_string(arguments, "query"),
         {:ok, limit} <- optional_limit(arguments),
         :ok <- reject_unknown_arguments(arguments),
         {:ok, before} <- decode_cursor(Map.get(arguments, "cursor"), scope, query),
         {:ok, page} <- Logs.search_logs(scope, query, limit: limit, before: before) do
      {:ok, search_result(scope, query, page)}
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
        "Search logs using WhisperLogs query syntax and return a newest-first page. Plain terms search messages and metadata. Supports quoted phrases, -exclusions, /regex/, metadata key:value and numeric comparisons, plus level:, source:, and timestamp:. An empty query returns the newest logs.",
      "inputSchema" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "maxLength" => 4_096,
            "description" => "WhisperLogs search query. Use an empty string for newest logs."
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
        "required" => ["query"],
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

  defp search_result(scope, query, %{logs: logs, has_more: database_has_more}) do
    max_bytes = WhisperLogs.Config.mcp_limits().max_response_bytes

    {included, size_truncated?} = fit_logs(logs, max_bytes)
    has_more = database_has_more or size_truncated?

    next_cursor =
      case {has_more, List.last(included)} do
        {true, log} when not is_nil(log) -> encode_cursor(scope, query, log)
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

  defp encode_cursor(%Scope{user: user}, query, log) do
    Phoenix.Token.encrypt(
      WhisperLogsWeb.Endpoint,
      @cursor_salt,
      %{
        "user_id" => user.id,
        "query" => query,
        "observed_at" => DateTime.to_iso8601(log.inserted_at),
        "id" => log.id
      },
      max_age: @cursor_lifetime_seconds
    )
  end

  defp decode_cursor(nil, _scope, _query), do: {:ok, nil}
  defp decode_cursor("", _scope, _query), do: {:error, :invalid_cursor}

  defp decode_cursor(cursor, %Scope{user: user}, query) when is_binary(cursor) do
    with {:ok, payload} <-
           Phoenix.Token.decrypt(WhisperLogsWeb.Endpoint, @cursor_salt, cursor,
             max_age: @cursor_lifetime_seconds
           ),
         %{
           "user_id" => user_id,
           "query" => ^query,
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

  defp required_string(arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, :invalid_arguments}
    end
  end

  defp optional_limit(arguments) do
    case Map.get(arguments, "limit", 50) do
      limit when is_integer(limit) and limit in 1..100 -> {:ok, limit}
      _ -> {:error, :invalid_limit}
    end
  end

  defp reject_unknown_arguments(arguments) do
    if Enum.all?(Map.keys(arguments), &(&1 in ~w(query limit cursor))),
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
        _ -> "Invalid search_logs arguments."
      end

    %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => message}],
      "isError" => true
    }
  end
end
