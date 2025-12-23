defmodule WhisperLogs.Syslog.Parser do
  @moduledoc """
  Parser for RFC 3164 (BSD) and RFC 5424 (IETF) syslog message formats.
  Auto-detects format based on message structure.
  """

  # Map syslog severity to log levels
  @severity_map %{
    # Emergency
    0 => "error",
    # Alert
    1 => "error",
    # Critical
    2 => "error",
    # Error
    3 => "error",
    # Warning
    4 => "warning",
    # Notice
    5 => "info",
    # Informational
    6 => "info",
    # Debug
    7 => "debug"
  }

  @facility_names %{
    0 => "kern",
    1 => "user",
    2 => "mail",
    3 => "daemon",
    4 => "auth",
    5 => "syslog",
    6 => "lpr",
    7 => "news",
    8 => "uucp",
    9 => "cron",
    10 => "authpriv",
    11 => "ftp",
    16 => "local0",
    17 => "local1",
    18 => "local2",
    19 => "local3",
    20 => "local4",
    21 => "local5",
    22 => "local6",
    23 => "local7"
  }

  @month_map %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  @doc """
  Parses a syslog message and returns a map suitable for Logs.insert_batch/2.

  Returns `{:ok, parsed_log}` or `{:error, reason}`.

  ## Examples

      iex> Parser.parse("<34>Oct 11 22:14:15 mymachine su: 'su root' failed")
      {:ok, %{"timestamp" => "...", "level" => "error", "message" => "...", "metadata" => %{...}}}
  """
  def parse(message) when is_binary(message) do
    message = String.trim(message)

    case message do
      "<" <> _ ->
        case detect_format(message) do
          :rfc5424 -> parse_rfc5424(message)
          :rfc3164 -> parse_rfc3164(message)
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  # RFC 5424 has version number after PRI: <PRI>VERSION TIMESTAMP...
  # RFC 3164 has timestamp directly after PRI: <PRI>MMM DD HH:MM:SS...
  defp detect_format(message) do
    # RFC 5424: <PRI>VERSION where VERSION is a digit
    case Regex.run(~r/^<\d{1,3}>(\d)\s/, message) do
      [_, _version] -> :rfc5424
      _ -> :rfc3164
    end
  end

  # RFC 3164 format: <PRI>TIMESTAMP HOSTNAME TAG: MSG
  # Example: <34>Oct 11 22:14:15 mymachine su: 'su root' failed
  defp parse_rfc3164(message) do
    case Regex.run(~r/^<(\d{1,3})>(.*)$/s, message) do
      [_, pri_str, rest] ->
        pri = String.to_integer(pri_str)
        {facility, severity} = decode_pri(pri)

        {timestamp, hostname, msg} = parse_bsd_header(rest)

        {:ok,
         %{
           "timestamp" => timestamp || DateTime.utc_now() |> DateTime.to_iso8601(),
           "level" => severity,
           "message" => msg,
           "metadata" => %{
             "facility" => facility,
             "hostname" => hostname,
             "format" => "rfc3164"
           }
         }}

      _ ->
        {:error, :parse_failed}
    end
  end

  # RFC 5424 format: <PRI>VERSION TIMESTAMP HOSTNAME APP-NAME PROCID MSGID SD MSG
  # Example: <34>1 2003-10-11T22:14:15.003Z mymachine.example.com su - ID47 - 'su root' failed
  defp parse_rfc5424(message) do
    # More permissive regex for structured data and message
    regex = ~r/^<(\d{1,3})>(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(-|\[.*?\])\s*(.*)$/s

    case Regex.run(regex, message) do
      [_, pri_str, _version, timestamp, hostname, appname, procid, _msgid, sd, msg] ->
        pri = String.to_integer(pri_str)
        {facility, severity} = decode_pri(pri)

        metadata =
          %{
            "facility" => facility,
            "hostname" => nilify(hostname),
            "appname" => nilify(appname),
            "procid" => nilify(procid),
            "format" => "rfc5424"
          }
          |> maybe_add_structured_data(sd)
          |> reject_nils()

        {:ok,
         %{
           "timestamp" => parse_rfc5424_timestamp(timestamp),
           "level" => severity,
           "message" => msg,
           "metadata" => metadata
         }}

      _ ->
        {:error, :parse_failed}
    end
  end

  defp decode_pri(pri) when is_integer(pri) do
    facility = div(pri, 8)
    severity = rem(pri, 8)
    {Map.get(@facility_names, facility, "unknown"), Map.get(@severity_map, severity, "info")}
  end

  # Parse BSD syslog header: "MMM DD HH:MM:SS hostname msg" or "MMM  D HH:MM:SS hostname msg"
  defp parse_bsd_header(rest) do
    case Regex.run(
           ~r/^([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\S+)\s+(.*)$/s,
           rest
         ) do
      [_, month_str, day, hour, min, sec, hostname, msg] ->
        timestamp = build_bsd_timestamp(month_str, day, hour, min, sec)
        {timestamp, hostname, msg}

      _ ->
        # If we can't parse the header, return the whole thing as the message
        {nil, nil, rest}
    end
  end

  defp build_bsd_timestamp(month_str, day, hour, min, sec) do
    year = DateTime.utc_now().year
    month = Map.get(@month_map, month_str, 1)

    case NaiveDateTime.new(
           year,
           month,
           String.to_integer(day),
           String.to_integer(hour),
           String.to_integer(min),
           String.to_integer(sec),
           {0, 6}
         ) do
      {:ok, ndt} ->
        DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_iso8601(:extended)

      {:error, _} ->
        DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp parse_rfc5424_timestamp("-"), do: DateTime.utc_now() |> DateTime.to_iso8601()
  # RFC 5424 timestamps are already ISO8601
  defp parse_rfc5424_timestamp(ts), do: ts

  defp maybe_add_structured_data(metadata, "-"), do: metadata
  defp maybe_add_structured_data(metadata, sd), do: Map.put(metadata, "structured_data", sd)

  defp nilify("-"), do: nil
  defp nilify(val), do: val

  defp reject_nils(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end
end
