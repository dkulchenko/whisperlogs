defmodule WhisperLogs.Exports do
  @moduledoc """
  The Exports context for managing log export destinations and jobs.
  """
  import Ecto.Query, warn: false

  alias WhisperLogs.Repo
  alias WhisperLogs.Exports.{ExportDestination, ExportJob}
  alias WhisperLogs.Accounts.{User, Scope}
  alias WhisperLogs.Logs.Log

  # ===== Export Destinations =====

  @doc """
  Lists all export destinations for a scope.
  """
  def list_export_destinations(%Scope{user: %User{id: user_id}}) do
    ExportDestination
    |> where([d], d.user_id == ^user_id)
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single export destination for a scope.
  """
  def get_export_destination(%Scope{user: %User{id: user_id}}, id) do
    ExportDestination
    |> where([d], d.user_id == ^user_id and d.id == ^id)
    |> Repo.one()
  end

  @doc """
  Gets a single export destination for a scope. Raises if not found.
  """
  def get_export_destination!(%Scope{user: %User{id: user_id}}, id) do
    ExportDestination
    |> where([d], d.user_id == ^user_id and d.id == ^id)
    |> Repo.one!()
  end

  @doc """
  Creates an export destination for a scope.
  """
  def create_export_destination(%Scope{user: %User{id: user_id}}, attrs) do
    %ExportDestination{user_id: user_id}
    |> ExportDestination.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an export destination.
  """
  def update_export_destination(%ExportDestination{} = destination, attrs) do
    destination
    |> ExportDestination.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an export destination.
  """
  def delete_export_destination(%ExportDestination{} = destination) do
    Repo.delete(destination)
  end

  @doc """
  Toggles an export destination's enabled status.
  """
  def toggle_export_destination(%ExportDestination{} = destination) do
    destination
    |> Ecto.Changeset.change(enabled: !destination.enabled)
    |> Repo.update()
  end

  @doc """
  Returns an ExportDestination changeset for form validation.
  """
  def change_export_destination(%ExportDestination{} = destination, attrs \\ %{}) do
    ExportDestination.changeset(destination, attrs)
  end

  @doc """
  Lists all export destinations with auto-export enabled.
  Used by the scheduler.
  """
  def list_auto_export_destinations do
    ExportDestination
    |> where([d], d.enabled == true and d.auto_export_enabled == true)
    |> Repo.all()
  end

  # ===== Export Jobs =====

  @doc """
  Lists export jobs for a scope.
  """
  def list_export_jobs(%Scope{user: %User{id: user_id}}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    ExportJob
    |> where([j], j.user_id == ^user_id)
    |> order_by([j], desc: j.inserted_at)
    |> limit(^limit)
    |> preload(:export_destination)
    |> Repo.all()
  end

  @doc """
  Lists export jobs for a specific destination.
  """
  def list_export_jobs_for_destination(%ExportDestination{id: destination_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    ExportJob
    |> where([j], j.export_destination_id == ^destination_id)
    |> order_by([j], desc: j.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets a single export job.
  """
  def get_export_job(%Scope{user: %User{id: user_id}}, id) do
    ExportJob
    |> where([j], j.user_id == ^user_id and j.id == ^id)
    |> preload(:export_destination)
    |> Repo.one()
  end

  @doc """
  Gets an export job by ID. Used by exporter worker.
  """
  def get_export_job!(id) do
    ExportJob
    |> preload(:export_destination)
    |> Repo.get!(id)
  end

  @doc """
  Creates an export job for a destination.

  The `scope` parameter can be nil for scheduled jobs.
  """
  def create_export_job(%ExportDestination{} = destination, scope, attrs) do
    user_id =
      case scope do
        %Scope{user: %User{id: id}} -> id
        nil -> destination.user_id
      end

    %ExportJob{export_destination_id: destination.id, user_id: user_id}
    |> ExportJob.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an export job's status.
  """
  def update_export_job(%ExportJob{} = job, attrs) do
    job
    |> ExportJob.status_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Gets the end timestamp of the last successful export for a destination.
  Used to determine where to resume scheduled exports.
  """
  def get_last_successful_export_end(%ExportDestination{id: destination_id}) do
    ExportJob
    |> where([j], j.export_destination_id == ^destination_id and j.status == "completed")
    |> order_by([j], desc: j.to_timestamp)
    |> limit(1)
    |> select([j], j.to_timestamp)
    |> Repo.one()
  end

  @doc """
  Returns an ExportJob changeset for form validation.
  """
  def change_export_job(%ExportJob{} = job, attrs \\ %{}) do
    ExportJob.changeset(job, attrs)
  end

  # ===== Cleanup =====

  @doc """
  Deletes export jobs older than the given cutoff datetime.
  Used by retention cleanup.
  """
  def delete_jobs_before(%DateTime{} = cutoff) do
    ExportJob
    |> where([j], j.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end

  # ===== Log Streaming for Export =====

  @doc """
  Streams logs within a time range for export.

  Uses `Repo.stream` with batching for memory efficiency.
  Logs are ordered by timestamp ascending for chronological export.

  Must be called within a transaction.
  """
  def stream_logs_for_export(from_timestamp, to_timestamp) do
    Log
    |> where([l], l.timestamp >= ^from_timestamp and l.timestamp < ^to_timestamp)
    |> order_by([l], asc: l.timestamp, asc: l.id)
    |> Repo.stream(max_rows: 1000)
  end
end
