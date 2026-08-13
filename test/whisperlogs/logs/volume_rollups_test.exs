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

    test "SQLite cursor query plans remain ordered index range scans" do
      cursor = ~U[2026-08-13 01:06:10.824287Z]
      cursor_id = 17_222_072
      lower_bound = ~U[2026-07-14 01:06:10.824287Z]
      upper_bound = ~U[2026-08-14 01:06:10.824287Z]

      queries = [
        Log
        |> where(^DbAdapter.observed_before(cursor, cursor_id))
        |> where([l], l.inserted_at >= ^lower_bound)
        |> order_by([l], desc: l.inserted_at, desc: l.id)
        |> limit(401),
        Log
        |> where(^DbAdapter.observed_through(cursor, cursor_id))
        |> where([l], l.inserted_at >= ^lower_bound)
        |> order_by([l], desc: l.inserted_at, desc: l.id)
        |> limit(401),
        Log
        |> where(^DbAdapter.observed_after(cursor, cursor_id))
        |> where([l], l.inserted_at <= ^upper_bound)
        |> order_by([l], asc: l.inserted_at, asc: l.id)
        |> limit(401)
      ]

      for query <- queries do
        plan = explain_query(query)

        assert plan =~ "logs_observed_time_index"
        refute plan =~ "MULTI-INDEX OR"
        refute plan =~ "TEMP B-TREE"
      end
    end

    defp explain(sql) do
      Repo.query!("EXPLAIN QUERY PLAN " <> sql).rows
      |> Enum.map_join("\n", fn row -> Enum.at(row, -1) end)
    end

    defp explain_query(query) do
      {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo.impl(), query)
      explain(sql, params)
    end

    defp explain(sql, params) do
      Repo.query!("EXPLAIN QUERY PLAN " <> sql, params).rows
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
