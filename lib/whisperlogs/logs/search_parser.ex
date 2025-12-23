defmodule WhisperLogs.Logs.SearchParser do
  @moduledoc """
  Parses search query strings into structured tokens for log filtering.

  Supports:
  - Plain terms: `error` - search message and all metadata values
  - Metadata filters: `user_id:123` - filter by specific metadata key
  - Negative terms: `-oban` - exclude matches
  - Negative metadata: `-level:debug` - exclude specific metadata key-value
  - Quoted phrases: `"error in module"` - exact phrase match
  - Combined: `error user_id:123 -debug` - multiple conditions (AND logic)
  """

  @type token ::
          {:term, String.t()}
          | {:phrase, String.t()}
          | {:exclude, String.t()}
          | {:metadata, String.t(), String.t()}
          | {:exclude_metadata, String.t(), String.t()}

  @type parse_result :: {:ok, [token()]} | {:error, String.t()}

  @doc """
  Parses a search query string into a list of tokens.

  ## Examples

      iex> SearchParser.parse("error user_id:123 -debug")
      {:ok, [
        {:term, "error"},
        {:metadata, "user_id", "123"},
        {:exclude, "debug"}
      ]}

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
    # Match: quoted strings with optional -key: prefix, key:value pairs, or plain words
    # Order matters - more specific patterns first
    regex = ~r/
      -[\w.-]+:"[^"]*"      |  # -key:"quoted value"
      [\w.-]+:"[^"]*"       |  # key:"quoted value"
      "[^"]*"               |  # "quoted phrase"
      -[\w.-]+:[\w.-]+      |  # -key:value
      [\w.-]+:[\w.-]+       |  # key:value
      -[\w.-]+              |  # -term
      [\w.-]+                  # plain term
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
      [key, value] when key != "" ->
        {type, key, unquote_value(value)}

      _ ->
        nil
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
