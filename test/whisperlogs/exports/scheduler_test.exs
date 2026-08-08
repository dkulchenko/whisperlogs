defmodule WhisperLogs.Exports.SchedulerTest do
  use WhisperLogs.DataCase, async: false

  import WhisperLogs.AccountsFixtures
  import WhisperLogs.ExportsFixtures
  import WhisperLogs.LogsFixtures

  alias WhisperLogs.Exports.{ExportJob, S3ClientMock, Scheduler}
  alias WhisperLogs.Logs.Log
  alias WhisperLogs.Repo

  test "a failed scheduled range waits for a later tick instead of spinning" do
    Application.put_env(:whisperlogs, :s3_client, S3ClientMock)
    S3ClientMock.set_response(:error)

    on_exit(fn ->
      S3ClientMock.set_response(:ok)
      Application.delete_env(:whisperlogs, :s3_client)
    end)

    scope = user_scope_fixture()

    _destination =
      s3_destination_fixture(scope, auto_export_enabled: true, auto_export_age_days: 1)

    log = log_fixture("scheduled-source")
    observed_at = DateTime.add(DateTime.utc_now(:second), -3, :day)
    Repo.update_all(from(l in Log, where: l.id == ^log.id), set: [inserted_at: observed_at])

    scheduler = start_supervised!(Scheduler)
    _ = :sys.get_state(scheduler)

    failed_count =
      Repo.aggregate(
        from(j in ExportJob, where: j.trigger == "scheduled" and j.status == "failed"),
        :count
      )

    assert failed_count == 1
    _ = :sys.get_state(scheduler)

    assert Repo.aggregate(
             from(j in ExportJob, where: j.trigger == "scheduled" and j.status == "failed"),
             :count
           ) == 1
  end
end
