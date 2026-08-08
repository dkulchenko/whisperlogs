defmodule WhisperLogs.Repo.Migrations.AddSyslogEnabledAdmissionAndTlsFields do
  use Ecto.Migration
  import WhisperLogs.MigrationHelpers

  def up do
    alter table(:sources) do
      add :enabled, :boolean, null: false, default: true
      add :admission_mode, :string, null: false, default: "allowlist"
      add :tls_framing, :string

      if postgres?() do
        add :tls_client_identities, {:array, :string}, null: false, default: []
      else
        add :tls_client_identities, :string, null: false, default: "[]"
      end
    end

    execute """
    UPDATE sources
    SET admission_mode = CASE WHEN auto_register_hosts THEN 'any' ELSE 'allowlist' END,
        enabled = CASE WHEN type = 'syslog' THEN FALSE ELSE TRUE END
    """

    if postgres?() do
      create constraint(:sources, :sources_admission_mode_check,
               check: "admission_mode IN ('allowlist', 'any')"
             )

      create constraint(:sources, :sources_tls_framing_check,
               check: "tls_framing IS NULL OR tls_framing IN ('octet_counted', 'newline')"
             )
    else
      {insert_trigger, update_trigger} = sqlite_validation_triggers()
      execute(insert_trigger)
      execute(update_trigger)
    end

    drop_if_exists index(:sources, [:port], name: :sources_port_active_index)

    create unique_index(:sources, [:port],
             where: "type = 'syslog' AND revoked_at IS NULL AND enabled = TRUE",
             name: :sources_port_active_index
           )
  end

  def down do
    drop_if_exists index(:sources, [:port], name: :sources_port_active_index)

    if postgres?() do
      drop constraint(:sources, :sources_tls_framing_check)
      drop constraint(:sources, :sources_admission_mode_check)
    else
      execute("DROP TRIGGER sources_security_fields_insert")
      execute("DROP TRIGGER sources_security_fields_update")
    end

    alter table(:sources) do
      remove :tls_client_identities
      remove :tls_framing
      remove :admission_mode
      remove :enabled
    end

    create unique_index(:sources, [:port],
             where: "type = 'syslog' AND revoked_at IS NULL",
             name: :sources_port_active_index
           )
  end

  defp sqlite_validation_triggers do
    insert_trigger = """
    CREATE TRIGGER sources_security_fields_insert
    BEFORE INSERT ON sources
    WHEN NEW.admission_mode NOT IN ('allowlist', 'any')
      OR (NEW.tls_framing IS NOT NULL AND NEW.tls_framing NOT IN ('octet_counted', 'newline'))
    BEGIN
      SELECT RAISE(ABORT, 'invalid source security fields');
    END;
    """

    update_trigger = """
    CREATE TRIGGER sources_security_fields_update
    BEFORE UPDATE OF admission_mode, tls_framing ON sources
    WHEN NEW.admission_mode NOT IN ('allowlist', 'any')
      OR (NEW.tls_framing IS NOT NULL AND NEW.tls_framing NOT IN ('octet_counted', 'newline'))
    BEGIN
      SELECT RAISE(ABORT, 'invalid source security fields');
    END;
    """

    {insert_trigger, update_trigger}
  end
end
