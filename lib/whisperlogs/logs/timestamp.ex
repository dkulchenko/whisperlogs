defmodule WhisperLogs.Logs.Timestamp do
  @moduledoc """
  Parses client-supplied RFC 3339 timestamps into the form logs are stored in.

  Every result is UTC with microsecond precision, which is what `:utc_datetime_usec`
  requires, and lies in the range both database adapters can store and read back.
  """

  # PostgreSQL's earliest timestamp, and the last instant of the latest year Ecto can load
  # from SQLite's stored text. An offset can carry an otherwise valid value past either.
  @earliest ~U[-4713-11-24 00:00:00.000000Z]
  @latest ~U[9999-12-31 23:59:59.999999Z]

  @leap_second ~r/^(.*:)60(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})$/

  @spec parse(String.t()) :: {:ok, DateTime.t()} | {:error, :invalid_rfc3339 | :out_of_range}
  def parse(value) when is_binary(value) do
    # RFC 3339 allows a lowercase "t" and "z"; DateTime.from_iso8601/1 does not.
    value = String.upcase(value)

    case Regex.run(@leap_second, value) do
      [_, through_minute, offset] -> parse_leap_second(through_minute <> "59" <> offset)
      nil -> parse_iso8601(value)
    end
  end

  @doc """
  Returns whether both database adapters can store the datetime.
  """
  def in_range?(%DateTime{} = datetime) do
    DateTime.compare(datetime, @earliest) != :lt and DateTime.compare(datetime, @latest) != :gt
  end

  # Elixir has no leap second, so 23:59:60 becomes the last instant before the next second.
  defp parse_leap_second(value) do
    case parse_iso8601(value) do
      {:ok, %DateTime{hour: 23, minute: 59} = datetime} ->
        {:ok, %{datetime | microsecond: {999_999, 6}}}

      {:ok, _not_a_leap_second} ->
        {:error, :invalid_rfc3339}

      error ->
        error
    end
  end

  defp parse_iso8601(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        if in_range?(datetime),
          do: {:ok, normalize_precision(datetime)},
          else: {:error, :out_of_range}

      {:error, _reason} ->
        {:error, :invalid_rfc3339}
    end
  end

  defp normalize_precision(%DateTime{microsecond: {microsecond, _precision}} = datetime) do
    %{datetime | microsecond: {microsecond, 6}}
  end
end
