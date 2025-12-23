defmodule WhisperLogs.Alerts.Notifier.Email do
  @moduledoc """
  Email notification sender for alerts.
  Uses existing Swoosh/Mailer infrastructure.
  """

  import Swoosh.Email
  alias WhisperLogs.Mailer

  def send(channel, alert, trigger_type, trigger_data) do
    email = build_email(channel, alert, trigger_type, trigger_data)

    case Mailer.deliver(email) do
      {:ok, _} -> %{success: true, error: nil}
      {:error, reason} -> %{success: false, error: inspect(reason)}
    end
  end

  defp build_email(channel, alert, trigger_type, trigger_data) do
    recipient = channel.config["email"]
    subject = build_subject(alert, trigger_type)
    body = build_body(alert, trigger_type, trigger_data)

    new()
    |> to(recipient)
    |> from({"WhisperLogs Alerts", from_email()})
    |> subject(subject)
    |> text_body(body)
  end

  defp from_email do
    Application.get_env(:whisperlogs, :alert_from_email, "alerts@whisperlogs.local")
  end

  defp build_subject(alert, "any_match") do
    "[WhisperLogs] Alert: #{alert.name}"
  end

  defp build_subject(alert, "velocity") do
    "[WhisperLogs] Velocity Alert: #{alert.name}"
  end

  defp build_body(alert, "any_match", trigger_data) do
    """
    Alert: #{alert.name}
    Type: Log Match

    A log entry matched your alert criteria.

    Query: #{alert.search_query}

    Matching Log:
    - Level: #{trigger_data["log_level"]}
    - Source: #{trigger_data["log_source"]}
    - Time: #{trigger_data["log_timestamp"]}
    - Message: #{trigger_data["log_message"]}
    """
  end

  defp build_body(alert, "velocity", trigger_data) do
    window_label = format_window(trigger_data["window_seconds"])

    """
    Alert: #{alert.name}
    Type: Log Velocity

    Log velocity exceeded threshold.

    Query: #{alert.search_query}

    Details:
    - Count: #{trigger_data["count"]} logs
    - Threshold: #{trigger_data["threshold"]} logs
    - Time Window: #{window_label}
    """
  end

  defp format_window(60), do: "1 minute"
  defp format_window(300), do: "5 minutes"
  defp format_window(900), do: "15 minutes"
  defp format_window(3600), do: "1 hour"
  defp format_window(s), do: "#{s} seconds"
end
