defmodule WhisperLogs.Repo.Migrations.CreateExportTables do
  use Ecto.Migration
  import WhisperLogs.MigrationHelpers

  def change do
    create table(:export_destinations) do
      if postgres?() do
        add :user_id, references(:users, on_delete: :delete_all), null: false
      else
        add :user_id, :integer
      end

      add :name, :string, null: false
      add :destination_type, :string, null: false
      add :enabled, :boolean, default: true, null: false

      # Local destination settings
      add :local_path, :string

      # S3 destination settings
      add :s3_endpoint, :string
      add :s3_bucket, :string
      add :s3_region, :string
      add :s3_access_key_id, :string
      add :s3_secret_access_key, :string
      add :s3_prefix, :string

      # Auto-export settings
      add :auto_export_enabled, :boolean, default: false, null: false
      add :auto_export_age_days, :integer

      timestamps(type: :utc_datetime)
    end

    if postgres?() do
      create index(:export_destinations, [:user_id])
    end

    create table(:export_jobs) do
      add :export_destination_id, references(:export_destinations, on_delete: :delete_all),
        null: false

      if postgres?() do
        add :user_id, references(:users, on_delete: :delete_all)
      else
        add :user_id, :integer
      end

      add :status, :string, null: false, default: "pending"
      add :trigger, :string, null: false
      add :from_timestamp, :utc_datetime_usec
      add :to_timestamp, :utc_datetime_usec
      add :file_name, :string
      add :file_size_bytes, :bigint
      add :log_count, :bigint
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :error_message, :text

      timestamps(type: :utc_datetime)
    end

    create index(:export_jobs, [:export_destination_id])
    create index(:export_jobs, [:status])

    if postgres?() do
      create index(:export_jobs, [:user_id])
    end
  end
end
