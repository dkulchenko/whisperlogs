defmodule WhisperLogs.Logs.VolumeRollupsTest do
  use WhisperLogs.DataCase, async: false

  alias WhisperLogs.DbAdapter
  alias WhisperLogs.Logs
  alias WhisperLogs.Logs.{Log, VolumeRollups}

  import WhisperLogs.LogsFixtures

  test "increments hour and day totals atomically using UTF-8 bytes" do
    assert {:ok, [_log]} =
             Logs.insert_batch("api", [
               %{"message" => "☃", "metadata" => %{}}
             ])

    assert {1, 5} = Logs.total_volume()
    assert [{_hour, 1, 5}] = Logs.volume_by_hour(1)
    assert [{_day, 1, 5}] = Logs.volume_by_day(1)

    assert {:ok, [_log]} = Logs.insert_batch("api", [%{"message" => "ok", "metadata" => %{}}])
    assert {2, 9} = Logs.total_volume()
  end

  test "invalid batches change neither logs nor rollups" do
    assert {:error, _reason} = Logs.insert_batch("api", [%{"message" => 123}])
    assert Logs.count_logs() == 0
    assert Logs.total_volume() == {0, 0}
  end

  test "rebuild and retention keep totals equal to currently stored logs" do
    old = log_fixture("api", message: "old")
    recent = log_fixture("api", message: "recent")
    old_time = DateTime.add(DateTime.utc_now(), -60, :day)

    Repo.update_all(from(l in Log, where: l.id == ^old.id), set: [inserted_at: old_time])
    VolumeRollups.rebuild!()

    assert Logs.total_volume() == raw_totals()

    cutoff = DateTime.add(DateTime.utc_now(), -30, :day)
    assert {1, nil} = Logs.delete_before(cutoff)
    assert Logs.get_log(old.id) == nil
    assert Logs.get_log(recent.id) != nil
    assert Logs.total_volume() == raw_totals()
  end

  if DbAdapter.sqlite?() do
    test "SQLite query plans use observed-time indexes" do
      default_plan =
        explain("""
        SELECT id FROM logs
        WHERE inserted_at >= '2000-01-01T00:00:00.000000Z'
        ORDER BY inserted_at DESC, id DESC LIMIT 500
        """)

      assert default_plan =~ "logs_observed_time_index"
      refute default_plan =~ "TEMP B-TREE"

      explicit_columns =
        Repo.query!("PRAGMA index_info(logs_observed_time_index)").rows
        |> Enum.map(fn row -> Enum.at(row, 2) end)

      assert explicit_columns == ["inserted_at"]

      level_plan =
        explain("""
        SELECT id FROM logs
        WHERE level = 'error' AND inserted_at >= '2000-01-01T00:00:00.000000Z'
        ORDER BY inserted_at DESC, id DESC LIMIT 500
        """)

      assert level_plan =~ "logs_level_observed_time_index"

      source_plan =
        explain("""
        SELECT id FROM logs
        WHERE source = 'api' AND inserted_at >= '2000-01-01T00:00:00.000000Z'
        ORDER BY inserted_at DESC, id DESC LIMIT 500
        """)

      assert source_plan =~ "logs_source_observed_time_index"
    end

    defp explain(sql) do
      Repo.query!("EXPLAIN QUERY PLAN " <> sql).rows
      |> Enum.map_join("\n", fn row -> Enum.at(row, -1) end)
    end
  end

  defp raw_totals do
    volume_select = DbAdapter.volume_select_total()

    case Log |> select([l], ^volume_select) |> Repo.one() do
      %{count: nil, bytes: nil} -> {0, 0}
      %{count: count, bytes: bytes} -> {count, bytes || 0}
    end
  end
end
