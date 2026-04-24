defmodule WhisperLogs.Alerts.Notifier.Slack do
  @moduledoc """
  Slack incoming webhook notification sender for alerts.

  Uses the Req HTTP library per project guidelines.
  """

  def send(channel, alert, trigger_type, trigger_data) do
    payload = build_payload(alert, trigger_type, trigger_data)

    case client().post(channel.config["webhook_url"], payload) do
      {:ok, %{status: 200, body: "ok"}} ->
        %{success: true, error: nil}

      {:ok, %{status: status, body: body}} ->
        %{success: false, error: "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        %{success: false, error: inspect(reason)}
    end
  end

  defp client do
    Application.get_env(:whisperlogs, :slack_webhook_client, __MODULE__.Client)
  end

  defp build_payload(alert, "any_match", trigger_data) do
    title = "Log Match: #{alert.name}"
    message = trigger_data["log_message"] || ""
    level = trigger_data["log_level"] || "unknown"
    source = trigger_data["log_source"] || "unknown"

    %{
      text: "#{title} - #{level}: #{message}",
      blocks: [
        header_block(title),
        section_block("*#{escape_mrkdwn(level)}* from `#{escape_mrkdwn(source)}`"),
        section_block(escape_mrkdwn(message)),
        context_block(["Query: `#{escape_mrkdwn(alert.search_query)}`"])
      ]
    }
  end

  defp build_payload(alert, "velocity", trigger_data) do
    title = "Velocity Alert: #{alert.name}"
    count = trigger_data["count"] || 0
    threshold = trigger_data["threshold"] || "unknown"
    window = format_window(trigger_data["window_seconds"])

    %{
      text: "#{title} - #{count} matches in #{window}",
      blocks: [
        header_block(title),
        section_block("*#{count}* matches in #{escape_mrkdwn(window)}"),
        context_block([
          "Threshold: `#{threshold}`",
          "Query: `#{escape_mrkdwn(alert.search_query)}`"
        ])
      ]
    }
  end

  defp header_block(text) do
    %{
      type: "header",
      text: %{
        type: "plain_text",
        text: truncate(text, 150),
        emoji: true
      }
    }
  end

  defp section_block(text) do
    %{
      type: "section",
      text: %{
        type: "mrkdwn",
        text: truncate(text, 3_000)
      }
    }
  end

  defp context_block(elements) do
    %{
      type: "context",
      elements:
        Enum.map(elements, fn text ->
          %{type: "mrkdwn", text: truncate(to_string(text), 300)}
        end)
    }
  end

  defp escape_mrkdwn(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp truncate(text, max_length) do
    text = to_string(text)

    if String.length(text) > max_length do
      String.slice(text, 0, max_length - 3) <> "..."
    else
      text
    end
  end

  defp format_window(60), do: "1m"
  defp format_window(300), do: "5m"
  defp format_window(900), do: "15m"
  defp format_window(3600), do: "1h"
  defp format_window(s) when is_integer(s), do: "#{s}s"
  defp format_window(_), do: "unknown window"
end
