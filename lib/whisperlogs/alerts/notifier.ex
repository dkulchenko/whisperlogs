defmodule WhisperLogs.Alerts.Notifier do
  @moduledoc """
  Dispatches notifications for triggered alerts.
  """

  alias WhisperLogs.Alerts.Alert
  alias WhisperLogs.Alerts.Notifier.{Email, Pushover}

  @doc """
  Sends notifications for a triggered alert.
  Returns a list of notification results for history tracking.
  """
  def send_alert(%Alert{} = alert, trigger_type, trigger_data) do
    alert.notification_channels
    |> Enum.filter(& &1.enabled)
    |> Enum.map(fn channel ->
      result = send_to_channel(channel, alert, trigger_type, trigger_data)

      %{
        "channel_id" => channel.id,
        "channel_type" => channel.channel_type,
        "channel_name" => channel.name,
        "success" => result.success,
        "error" => result.error
      }
    end)
  end

  defp send_to_channel(%{channel_type: "email"} = channel, alert, trigger_type, trigger_data) do
    Email.send(channel, alert, trigger_type, trigger_data)
  end

  defp send_to_channel(%{channel_type: "pushover"} = channel, alert, trigger_type, trigger_data) do
    Pushover.send(channel, alert, trigger_type, trigger_data)
  end
end
