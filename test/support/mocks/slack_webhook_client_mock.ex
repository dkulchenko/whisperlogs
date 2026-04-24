defmodule WhisperLogs.Alerts.SlackWebhookClientMock do
  @moduledoc """
  Mock Slack webhook client for testing alert notifications without real HTTP calls.
  """

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{response: {:ok, %{status: 200, body: "ok"}}, calls: []} end,
      name: __MODULE__
    )
  end

  def set_response(response) do
    Agent.update(__MODULE__, &Map.put(&1, :response, response))
  end

  def clear_calls do
    Agent.update(__MODULE__, &Map.put(&1, :calls, []))
  end

  def get_calls do
    Agent.get(__MODULE__, & &1.calls)
  end

  def post(webhook_url, payload) do
    call = {:slack_webhook_post, webhook_url, payload}
    send(self(), call)

    Agent.update(__MODULE__, fn state ->
      %{state | calls: [call | state.calls]}
    end)

    Agent.get(__MODULE__, & &1.response)
  end
end
