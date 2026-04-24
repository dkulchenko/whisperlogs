defmodule WhisperLogs.Alerts.Notifier.SlackTest do
  use WhisperLogs.DataCase, async: false

  import WhisperLogs.AccountsFixtures
  import WhisperLogs.AlertsFixtures

  alias WhisperLogs.Alerts.Notifier
  alias WhisperLogs.Alerts.SlackWebhookClientMock

  setup do
    Application.put_env(:whisperlogs, :slack_webhook_client, SlackWebhookClientMock)
    SlackWebhookClientMock.clear_calls()
    SlackWebhookClientMock.set_response({:ok, %{status: 200, body: "ok"}})

    on_exit(fn ->
      Application.delete_env(:whisperlogs, :slack_webhook_client)
      SlackWebhookClientMock.clear_calls()
      SlackWebhookClientMock.set_response({:ok, %{status: 200, body: "ok"}})
    end)

    :ok
  end

  test "sends a Slack webhook notification" do
    user = user_fixture()
    channel = slack_channel_fixture(user, webhook_url: "https://hooks.slack.com/services/T/B/C")
    alert = any_match_alert_fixture(user, channel_ids: [channel.id], search_query: "level:error")

    [result] =
      Notifier.send_alert(alert, "any_match", %{
        "log_level" => "error",
        "log_message" => "Request failed",
        "log_source" => "api"
      })

    assert result["success"] == true
    assert result["error"] == nil

    assert_received {:slack_webhook_post, "https://hooks.slack.com/services/T/B/C", payload}
    assert payload.text =~ "Log Match"
    assert payload.text =~ "Request failed"
    assert is_list(payload.blocks)
  end

  test "records non-200 Slack webhook responses" do
    SlackWebhookClientMock.set_response({:ok, %{status: 404, body: "no_service"}})

    user = user_fixture()
    channel = slack_channel_fixture(user)
    alert = any_match_alert_fixture(user, channel_ids: [channel.id])

    [result] =
      Notifier.send_alert(alert, "any_match", %{
        "log_level" => "error",
        "log_message" => "Request failed",
        "log_source" => "api"
      })

    assert result["success"] == false
    assert result["error"] =~ "HTTP 404"
    assert result["error"] =~ "no_service"
  end

  test "records Req errors from Slack webhook posts" do
    SlackWebhookClientMock.set_response({:error, :timeout})

    user = user_fixture()
    channel = slack_channel_fixture(user)
    alert = any_match_alert_fixture(user, channel_ids: [channel.id])

    [result] =
      Notifier.send_alert(alert, "any_match", %{
        "log_level" => "error",
        "log_message" => "Request failed",
        "log_source" => "api"
      })

    assert result["success"] == false
    assert result["error"] =~ "timeout"
  end
end
