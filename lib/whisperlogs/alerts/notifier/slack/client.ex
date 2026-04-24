defmodule WhisperLogs.Alerts.Notifier.Slack.Client do
  @moduledoc false

  def post(webhook_url, payload) do
    Req.post(webhook_url, json: payload)
  end
end
