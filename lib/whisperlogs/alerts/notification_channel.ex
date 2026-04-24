defmodule WhisperLogs.Alerts.NotificationChannel do
  @moduledoc """
  Schema for notification channels (email, pushover, slack).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @channel_types ~w(email pushover slack)

  schema "notification_channels" do
    field :channel_type, :string
    field :name, :string
    field :enabled, :boolean, default: true
    field :config, :map, default: %{}
    field :verified_at, :utc_datetime

    belongs_to :user, WhisperLogs.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:channel_type, :name, :enabled, :config])
    |> validate_required([:channel_type, :name, :config])
    |> validate_inclusion(:channel_type, @channel_types)
    |> validate_length(:name, min: 1, max: 100)
    |> validate_channel_config()
  end

  defp validate_channel_config(changeset) do
    channel_type = get_field(changeset, :channel_type)
    config = get_field(changeset, :config) || %{}

    case channel_type do
      "email" ->
        if valid_email?(config["email"]) do
          changeset
        else
          add_error(changeset, :config, "must include a valid email address")
        end

      "pushover" ->
        cond do
          !is_binary(config["user_key"]) or config["user_key"] == "" ->
            add_error(changeset, :config, "must include user_key")

          !is_binary(config["app_token"]) or config["app_token"] == "" ->
            add_error(changeset, :config, "must include app_token")

          config["priority"] != nil and config["priority"] not in -2..2 ->
            add_error(changeset, :config, "priority must be between -2 and 2")

          true ->
            changeset
        end

      "slack" ->
        if valid_slack_webhook_url?(config["webhook_url"]) do
          changeset
        else
          add_error(changeset, :config, "must include a valid Slack webhook URL")
        end

      _ ->
        changeset
    end
  end

  defp valid_email?(nil), do: false

  defp valid_email?(email) when is_binary(email),
    do: String.match?(email, ~r/^[^@,;\s]+@[^@,;\s]+$/)

  defp valid_email?(_), do: false

  defp valid_slack_webhook_url?(url) when is_binary(url) do
    uri = URI.parse(url)

    uri.scheme == "https" and
      uri.host in ["hooks.slack.com", "hooks.slack-gov.com"] and
      is_binary(uri.path) and
      String.starts_with?(uri.path, "/services/") and
      length(String.split(String.trim_leading(uri.path, "/services/"), "/", trim: true)) >= 3
  end

  defp valid_slack_webhook_url?(_), do: false
end
