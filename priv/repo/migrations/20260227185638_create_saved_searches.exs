defmodule WhisperLogs.Repo.Migrations.CreateSavedSearches do
  use Ecto.Migration
  import WhisperLogs.MigrationHelpers

  def change do
    create table(:saved_searches) do
      if postgres?() do
        add :user_id, references(:users, on_delete: :delete_all), null: false
      else
        add :user_id, :integer, null: false
      end

      add :name, :string, null: false
      add :search, :string, default: ""
      add :source, :string, default: ""
      add :levels, :string, default: "debug,info,warning,error"
      add :time_range, :string, default: "3h"

      timestamps(type: :utc_datetime)
    end

    if postgres?() do
      create index(:saved_searches, [:user_id])
    end

    create unique_index(:saved_searches, [:user_id, :name])
  end
end
