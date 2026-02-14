defmodule WhisperLogs.Release do
  @moduledoc """
  Release tasks for database management.

  For SQLite mode, this is called automatically on startup to ensure
  the database exists and migrations are run.

  For PostgreSQL mode, users can run migrations manually:

      ./whisperlogs eval "WhisperLogs.Release.migrate()"
  """

  import Ecto.Query

  alias WhisperLogs.Accounts.User
  alias WhisperLogs.Repo

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

    # For SQLite mode, ensure the default local user exists
    if WhisperLogs.DbAdapter.sqlite?() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(Repo, fn repo ->
          ensure_default_user(repo)
        end)
    end
  end

  @doc """
  Ensures a default local user exists for SQLite single-user mode.
  Returns the user.
  """
  def ensure_default_user(repo \\ Repo) do
    case repo.one(from u in User, where: u.email == "local@localhost", limit: 1) do
      nil ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        %User{}
        |> Ecto.Changeset.change(%{
          email: "local@localhost",
          is_admin: true,
          confirmed_at: now,
          inserted_at: now,
          updated_at: now
        })
        |> repo.insert!()

      user ->
        user
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
