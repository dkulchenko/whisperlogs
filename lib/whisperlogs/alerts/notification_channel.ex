defmodule WhisperLogs.Alerts.NotificationChannel do
  @moduledoc """
  Schema for notification channels (email, pushover).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @channel_types ~w(email pushover)

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

      _ ->
        changeset
    end
  end

  defp valid_email?(nil), do: false

  defp valid_email?(email) when is_binary(email),
    do: String.match?(email, ~r/^[^@,;\s]+@[^@,;\s]+$/)

  defp valid_email?(_), do: false
end
