defmodule WhisperLogs.Shipper.Handler do
  @moduledoc """
  Erlang :logger handler that forwards log events to `WhisperLogs.Shipper`.

  This handler is registered via `:logger.add_handler/3` and receives all log
  events that pass the configured filters. It formats events into maps and
  casts them to the Shipper GenServer for batched HTTP shipping.
  """

  alias WhisperLogs.Shipper

  @doc """
  Called when the handler is added via `:logger.add_handler/3`.
  """
  def adding_handler(config) do
    {:ok, config}
  end

  @doc """
  Called for each log event. Formats the event and sends to Shipper.

  This is a callback for Erlang's :logger handler - the second parameter
  is the handler config which we don't need.
  """
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    event = %{
      level: normalize_level(level),
      message: format_message(msg),
      timestamp: format_timestamp(meta),
      metadata: format_metadata(meta)
    }

    Shipper.log(event)
  end

  defp format_message({:string, message}) do
    IO.chardata_to_string(message)
  end

  defp format_message({:report, report}) when is_map(report) do
    inspect(report)
  end

  defp format_message({:report, report}) when is_list(report), do: inspect(report)

  defp format_message({format, args}) when is_list(format) do
    :io_lib.format(format, args) |> IO.chardata_to_string()
  end

  defp format_timestamp(meta) do
    case Map.get(meta, :time) do
      nil ->
        DateTime.utc_now() |> DateTime.to_iso8601()

      time_microseconds ->
        time_microseconds
        |> DateTime.from_unix!(:microsecond)
        |> DateTime.to_iso8601()
    end
  end

  @ignored_keys ~w(time gl pid mfa file line domain)a

  defp format_metadata(meta) do
    meta
    |> Map.drop(@ignored_keys)
    |> Map.new(fn {k, v} -> {k, safe_value(v)} end)
  end

  # Only convert types that Jason can't encode (PIDs, refs, functions, ports)
  # Jason handles atoms, strings, numbers, booleans, lists, and maps natively
  defp safe_value(value) when is_pid(value), do: inspect(value)
  defp safe_value(value) when is_reference(value), do: inspect(value)
  defp safe_value(value) when is_function(value), do: inspect(value)
  defp safe_value(value) when is_port(value), do: inspect(value)

  defp safe_value(value) when is_map(value),
    do: Map.new(value, fn {key, child} -> {safe_key(key), safe_value(child)} end)

  defp safe_value(value) when is_list(value), do: Enum.map(value, &safe_value/1)
  defp safe_value(value), do: value

  defp safe_key(key) when is_binary(key), do: key
  defp safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp safe_key(key), do: inspect(key)

  defp normalize_level(:debug), do: "debug"
  defp normalize_level(level) when level in [:info, :notice], do: "info"
  defp normalize_level(:warning), do: "warning"
  defp normalize_level(level) when level in [:error, :critical, :alert, :emergency], do: "error"
  defp normalize_level(_level), do: "info"
end
