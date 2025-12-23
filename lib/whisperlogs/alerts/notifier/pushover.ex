defmodule WhisperLogs.Alerts.Notifier.Pushover do
  @moduledoc """
  Pushover notification sender for alerts.
  Uses the Req HTTP library per project guidelines.
  """

  @pushover_api "https://api.pushover.net/1/messages.json"

  def send(channel, alert, trigger_type, trigger_data) do
    config = channel.config

    payload = %{
      token: config["app_token"],
      user: config["user_key"],
      title: build_title(alert, trigger_type),
      message: build_message(alert, trigger_type, trigger_data),
      priority: Map.get(config, "priority", 0)
    }

    case Req.post(@pushover_api, form: payload) do
      {:ok, %{status: 200}} ->
        %{success: true, error: nil}

      {:ok, %{status: status, body: body}} ->
        %{success: false, error: "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        %{success: false, error: inspect(reason)}
    end
  end

  defp build_title(alert, "any_match"), do: "Log Match: #{alert.name}"
  defp build_title(alert, "velocity"), do: "Velocity Alert: #{alert.name}"

  defp build_message(alert, "any_match", trigger_data) do
    """
    #{trigger_data["log_level"]}: #{trigger_data["log_message"]}
    Source: #{trigger_data["log_source"]}
    Query: #{alert.search_query}
    """
    |> String.trim()
  end

  defp build_message(alert, "velocity", trigger_data) do
    window = format_window(trigger_data["window_seconds"])

    """
    #{trigger_data["count"]} matches in #{window}
    Threshold: #{trigger_data["threshold"]}
    Query: #{alert.search_query}
    """
    |> String.trim()
  end

  defp format_window(60), do: "1m"
  defp format_window(300), do: "5m"
  defp format_window(900), do: "15m"
  defp format_window(3600), do: "1h"
  defp format_window(s), do: "#{s}s"
end
