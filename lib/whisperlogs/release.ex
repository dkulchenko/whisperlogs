defmodule WhisperLogs.Release do
  @moduledoc """
  Release tasks for database management.

  For SQLite mode, this is called automatically on startup to ensure
  the database exists and migrations are run.

  For PostgreSQL mode, users can run migrations manually:

      ./whisperlogs eval "WhisperLogs.Release.migrate()"
  """

  @app :whisperlogs

  @doc """
  Runs all pending migrations.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Migrates all data from a SQLite database into PostgreSQL.

  This is an offline production migration task. The application should be
  stopped before running it so the SQLite source cannot change during copy.
  """
  def migrate_sqlite_to_postgres do
    WhisperLogs.SQLiteToPostgresMigrator.migrate()
  end

  @doc """
  Creates the database and runs all pending migrations.
  Used for SQLite auto-setup on first run.
  """
  def create_and_migrate do
    load_app()

    # Ensure the database directory exists for SQLite
    if WhisperLogs.DbAdapter.sqlite?() do
      WhisperLogs.DbAdapter.ensure_db_directory!()
    end

    for repo <- repos() do
      # Create database if it doesn't exist
      case repo.__adapter__().storage_up(repo.config()) do
        :ok -> :ok
        {:error, :already_up} -> :ok
        {:error, _reason} -> :ok
      end

      # Run pending migrations
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Rolls back the last migration.
  """
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Some platforms require SSL when connecting to databases.
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
