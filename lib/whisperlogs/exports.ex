defmodule WhisperLogs.Exports do
  @moduledoc "Owner-scoped export destinations, admission, and log streaming."
  import Ecto.Query, warn: false

  alias WhisperLogs.Accounts.{Scope, User}
  alias WhisperLogs.Exports.{ExportDestination, ExportJob}
  alias WhisperLogs.Logs.Log
  alias WhisperLogs.Repo

  def list_export_destinations(%Scope{user: %User{id: user_id}}) do
    ExportDestination
    |> where([d], d.user_id == ^user_id)
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  def get_export_destination(%Scope{user: %User{id: user_id}}, id) do
    Repo.get_by(ExportDestination, id: id, user_id: user_id)
  end

  def get_export_destination!(%Scope{} = scope, id),
    do:
      get_export_destination(scope, id) ||
        raise(Ecto.NoResultsError, queryable: ExportDestination)

  def create_export_destination(%Scope{user: %User{id: user_id}}, attrs) do
    %ExportDestination{user_id: user_id}
    |> ExportDestination.changeset(Map.drop(attrs, [:local_path, "local_path"]))
    |> Repo.insert()
  end

  def update_export_destination(%Scope{} = scope, id, attrs) do
    case get_export_destination(scope, id) do
      nil ->
        {:error, :not_found}

      destination ->
        destination
        |> ExportDestination.changeset(Map.drop(attrs, [:local_path, "local_path"]))
        |> Repo.update()
    end
  end

  def delete_export_destination(%Scope{} = scope, id) do
    case get_export_destination(scope, id) do
      nil -> {:error, :not_found}
      destination -> Repo.delete(destination)
    end
  end

  def toggle_export_destination(%Scope{} = scope, id) do
    case get_export_destination(scope, id) do
      nil ->
        {:error, :not_found}

      destination ->
        destination |> Ecto.Changeset.change(enabled: !destination.enabled) |> Repo.update()
    end
  end

  def change_export_destination(%ExportDestination{} = destination, attrs \\ %{}),
    do: ExportDestination.changeset(destination, attrs)

  def destination_path(%ExportDestination{destination_type: "local", user_id: user_id, id: id}) do
    Path.join([
      WhisperLogs.Config.export_root(),
      Integer.to_string(user_id),
      Integer.to_string(id)
    ])
  end

  def list_auto_export_destinations do
    ExportDestination
    |> where([d], d.enabled and d.auto_export_enabled)
    |> order_by([d], asc: d.id)
    |> Repo.all()
  end

  def list_export_jobs(%Scope{user: %User{id: user_id}}, opts \\ []) do
    ExportJob
    |> where([j], j.user_id == ^user_id)
    |> order_by([j], desc: j.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> preload(:export_destination)
    |> Repo.all()
  end

  def get_export_job(%Scope{user: %User{id: user_id}}, id) do
    ExportJob
    |> where([j], j.id == ^id and j.user_id == ^user_id)
    |> preload(:export_destination)
    |> Repo.one()
  end

  def list_export_jobs_for_destination(
        %Scope{user: %User{id: user_id}},
        destination_id,
        opts \\ []
      ) do
    ExportJob
    |> where([j], j.user_id == ^user_id and j.export_destination_id == ^destination_id)
    |> order_by([j], desc: j.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 20))
    |> Repo.all()
  end

  def get_export_job!(id), do: ExportJob |> preload(:export_destination) |> Repo.get!(id)

  def create_manual_job(%Scope{user: %User{id: user_id}} = scope, destination_id, attrs) do
    limits = WhisperLogs.Config.export_limits()

    WhisperLogs.DbAdapter.serialized_transaction(:exports, fn ->
      destination = get_export_destination(scope, destination_id) || Repo.rollback(:not_found)
      if !destination.enabled, do: Repo.rollback(:destination_disabled)
      attrs = Map.put(attrs, :trigger, "manual")

      changeset =
        ExportJob.changeset(
          %ExportJob{export_destination_id: destination.id, user_id: user_id},
          attrs
        )

      validate_range!(changeset, limits.max_range_days)
      enforce_pending_quota!(user_id, limits)
      enforce_duplicate!(destination.id, changeset)
      changeset |> Repo.insert() |> unwrap!()
    end)
    |> notify_scheduler()
  end

  def admit_scheduled_job(%ExportDestination{} = destination, from_timestamp, to_timestamp) do
    limits = WhisperLogs.Config.export_limits()

    WhisperLogs.DbAdapter.serialized_transaction(:exports, fn ->
      enforce_pending_quota!(destination.user_id, limits)

      attrs = %{trigger: "scheduled", from_timestamp: from_timestamp, to_timestamp: to_timestamp}

      changeset =
        ExportJob.changeset(
          %ExportJob{export_destination_id: destination.id, user_id: destination.user_id},
          attrs
        )

      enforce_duplicate!(destination.id, changeset)
      changeset |> Repo.insert() |> unwrap!()
    end)
  end

  def next_pending_job do
    ExportJob
    |> where([j], j.status == "pending")
    |> order_by([j], asc: j.inserted_at, asc: j.id)
    |> limit(1)
    |> preload(:export_destination)
    |> Repo.one()
  end

  def fail_interrupted_jobs do
    now = DateTime.utc_now()

    ExportJob
    |> where([j], j.status == "running")
    |> Repo.update_all(
      set: [
        status: "failed",
        completed_at: now,
        error_message: "interrupted by application restart"
      ]
    )
  end

  def update_export_job(%ExportJob{} = job, attrs),
    do: job |> ExportJob.status_changeset(attrs) |> Repo.update()

  def get_last_successful_scheduled_export_end(%ExportDestination{id: id}) do
    ExportJob
    |> where(
      [j],
      j.export_destination_id == ^id and j.trigger == "scheduled" and j.status == "completed"
    )
    |> select([j], max(j.to_timestamp))
    |> Repo.one()
  end

  def earliest_protected_scheduled_time do
    ExportJob
    |> where([j], j.trigger == "scheduled" and j.status in ["pending", "running"])
    |> select([j], min(j.from_timestamp))
    |> Repo.one()
  end

  def oldest_observed_time do
    Log |> select([l], min(l.inserted_at)) |> Repo.one()
  end

  def delete_jobs_before(%DateTime{} = cutoff),
    do: ExportJob |> where([j], j.inserted_at < ^cutoff) |> Repo.delete_all()

  def stream_logs_for_export(from_timestamp, to_timestamp, "manual") do
    Log
    |> where([l], l.timestamp >= ^from_timestamp and l.timestamp < ^to_timestamp)
    |> order_by([l], asc: l.timestamp, asc: l.id)
    |> Repo.stream(max_rows: 1000)
  end

  def stream_logs_for_export(from_timestamp, to_timestamp, "scheduled") do
    Log
    |> where([l], l.inserted_at >= ^from_timestamp and l.inserted_at < ^to_timestamp)
    |> order_by([l], asc: l.inserted_at, asc: l.id)
    |> Repo.stream(max_rows: 1000)
  end

  defp validate_range!(changeset, max_days) do
    if changeset.valid? do
      from = Ecto.Changeset.get_field(changeset, :from_timestamp)
      to = Ecto.Changeset.get_field(changeset, :to_timestamp)
      if DateTime.diff(to, from, :second) > max_days * 86_400, do: Repo.rollback(:range_too_large)
      changeset
    else
      Repo.rollback(changeset)
    end
  end

  defp enforce_pending_quota!(user_id, limits) do
    pending = from j in ExportJob, where: j.status in ["pending", "running"]

    if Repo.aggregate(where(pending, [j], j.user_id == ^user_id), :count) >=
         limits.max_pending_per_user,
       do: Repo.rollback(:user_pending_quota_exceeded)

    if Repo.aggregate(pending, :count) >= limits.max_pending_global,
      do: Repo.rollback(:global_pending_quota_exceeded)
  end

  defp enforce_duplicate!(destination_id, changeset) do
    trigger = Ecto.Changeset.get_field(changeset, :trigger)
    from_timestamp = Ecto.Changeset.get_field(changeset, :from_timestamp)
    to_timestamp = Ecto.Changeset.get_field(changeset, :to_timestamp)

    duplicate? =
      ExportJob
      |> where(
        [j],
        j.export_destination_id == ^destination_id and j.trigger == ^trigger and
          j.from_timestamp == ^from_timestamp and j.to_timestamp == ^to_timestamp and
          j.status in ["pending", "running"]
      )
      |> Repo.exists?()

    if duplicate?, do: Repo.rollback(:duplicate_active_export)
  end

  defp notify_scheduler({:ok, _job} = result) do
    if Process.whereis(WhisperLogs.Exports.Scheduler),
      do: GenServer.cast(WhisperLogs.Exports.Scheduler, :drain)

    result
  end

  defp notify_scheduler(result), do: result
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
