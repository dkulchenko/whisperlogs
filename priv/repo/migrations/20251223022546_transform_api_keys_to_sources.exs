defmodule WhisperLogs.Repo.Migrations.TransformApiKeysToSources do
  use Ecto.Migration

  def change do
    # Add new columns for source types
    alter table(:api_keys) do
      add :type, :string, null: false, default: "http"
      add :port, :integer
      add :transport, :string
      add :allowed_hosts, {:array, :string}, default: []
      add :auto_register_hosts, :boolean, default: false
    end

    # Create unique index for syslog ports (only one source per port when active)
    create unique_index(:api_keys, [:port],
             where: "type = 'syslog' AND revoked_at IS NULL",
             name: :sources_port_active_index
           )

    # Rename table api_keys -> sources
    rename table(:api_keys), to: table(:sources)

    # Rename the existing unique index to use new table name
    drop_if_exists index(:api_keys, [:user_id, :source],
                     name: :api_keys_user_id_source_active_index
                   )

    create unique_index(:sources, [:user_id, :source],
             where: "revoked_at IS NULL",
             name: :sources_user_id_source_active_index
           )
  end
end
