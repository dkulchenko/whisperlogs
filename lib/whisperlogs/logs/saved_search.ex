defmodule WhisperLogs.Logs.SavedSearch do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_levels ~w(debug info warning error)
  @valid_time_ranges ~w(3h 12h 24h 7d 30d all)

  schema "saved_searches" do
    field :name, :string
    field :search, :string, default: ""
    field :source, :string, default: ""
    field :levels, :string, default: "debug,info,warning,error"
    field :time_range, :string, default: "3h"

    belongs_to :user, WhisperLogs.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(saved_search, attrs) do
    saved_search
    |> cast(attrs, [:name, :search, :source, :levels, :time_range])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_inclusion(:time_range, @valid_time_ranges)
    |> validate_levels()
    |> unique_constraint([:user_id, :name], message: "already exists")
  end

  defp validate_levels(changeset) do
    case get_field(changeset, :levels) do
      nil ->
        changeset

      levels ->
        values = String.split(levels, ",", trim: true)

        if Enum.all?(values, &(&1 in @valid_levels)) do
          changeset
        else
          add_error(changeset, :levels, "contains invalid level values")
        end
    end
  end
end
