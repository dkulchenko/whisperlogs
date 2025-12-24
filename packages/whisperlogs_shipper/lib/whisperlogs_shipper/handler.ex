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
      level: Atom.to_string(level),
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

  defp format_message({:report, report}) when is_list(report) do
    inspect(Map.new(report))
  end

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
  defp safe_value(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, safe_value(v)} end)
  defp safe_value(value) when is_list(value), do: Enum.map(value, &safe_value/1)
  defp safe_value(value), do: value
end
