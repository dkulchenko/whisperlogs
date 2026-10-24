defmodule WhisperLogs.Repo.Migrations.PartitionSqliteLogSearchByDay do
  use Ecto.Migration

  import WhisperLogs.MigrationHelpers

  # Each partition commits on its own, so rebuilding a large index keeps the WAL small.
  @disable_ddl_transaction true

  @partition_options "fts5(search_text, content='', columnsize=0, detail=none, tokenize='trigram')"
  @search_text "message || char(10) || coalesce(metadata, '{}')"

  def up do
    if sqlite?() do
      # An interrupted run leaves partitions behind; the logs it indexes are untouched.
      drop_partitions()

      query!("""
      CREATE TABLE log_search_partitions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        first_log_id INTEGER NOT NULL,
        started_at TEXT NOT NULL
      )
      """)

      bounds = day_bounds()
      {closed, [{current_day, current_first}]} = Enum.split(bounds, -1)

      closed
      |> Enum.zip(tl(bounds))
      |> Enum.each(fn {{day, first_log_id}, {_next_day, next_first_log_id}} ->
        transaction!(fn ->
          table = create_partition(day, first_log_id)

          query!(
            "INSERT INTO #{table}(rowid, search_text) SELECT id, #{@search_text} FROM logs WHERE id >= ? AND id < ?",
            [first_log_id, next_first_log_id]
          )
        end)
      end)

      transaction!(fn ->
        table = create_partition(current_day, current_first)

        query!(
          "INSERT INTO #{table}(rowid, search_text) SELECT id, #{@search_text} FROM logs WHERE id >= ?",
          [current_first]
        )

        for trigger <- ~w(logs_fts_after_insert logs_fts_after_update logs_fts_after_delete) do
          query!("DROP TRIGGER IF EXISTS #{trigger}")
        end

        query!(insert_trigger(table))
        query!("DROP TABLE IF EXISTS logs_fts")
      end)
    end
  end

  def down do
    if sqlite?() do
      transaction!(fn ->
        query!("DROP TRIGGER logs_fts_after_insert")

        query!("""
        CREATE VIRTUAL TABLE logs_fts USING fts5(
          search_text,
          content='',
          contentless_delete=1,
          detail=none,
          tokenize='trigram'
        )
        """)

        query!("INSERT INTO logs_fts(rowid, search_text) SELECT id, #{@search_text} FROM logs")
        query!(insert_trigger("logs_fts"))

        query!("""
        CREATE TRIGGER logs_fts_after_delete
        AFTER DELETE ON logs
        BEGIN
          DELETE FROM logs_fts WHERE rowid = old.id;
        END
        """)

        query!("""
        CREATE TRIGGER logs_fts_after_update
        AFTER UPDATE OF id, message, metadata ON logs
        BEGIN
          DELETE FROM logs_fts WHERE rowid = old.id;
          INSERT INTO logs_fts(rowid, search_text)
          VALUES (new.id, new.message || char(10) || coalesce(new.metadata, '{}'));
        END
        """)

        drop_partitions()
      end)
    end
  end

  # One {day, first_log_id} per UTC day with logs, oldest first. Ids cover every log
  # without gaps: the first day starts at id 1, and each later day at the first log
  # inserted that day, never below the previous day's start.
  defp day_bounds do
    %{rows: [[first_inserted_at, last_inserted_at]]} =
      query!("SELECT min(inserted_at), max(inserted_at) FROM logs")

    case first_inserted_at do
      nil ->
        %{rows: [[next_log_id]]} =
          query!("SELECT coalesce((SELECT seq FROM sqlite_sequence WHERE name = 'logs'), 0) + 1")

        [{Date.utc_today(), next_log_id}]

      _logs ->
        Date.range(date(first_inserted_at), date(last_inserted_at))
        |> Enum.flat_map(fn day ->
          case query!(
                 "SELECT id FROM logs WHERE inserted_at >= ? ORDER BY inserted_at, id LIMIT 1",
                 [DateTime.to_iso8601(day_start(day))]
               ).rows do
            [[id]] -> [{day, id}]
            [] -> []
          end
        end)
        |> Enum.uniq_by(fn {_day, id} -> id end)
        |> then(fn [{first_day, _id} | rest] -> [{first_day, 1} | rest] end)
        |> Enum.scan(fn {day, id}, {_previous_day, previous_id} ->
          {day, max(id, previous_id)}
        end)
    end
  end

  defp create_partition(%Date{} = day, first_log_id) do
    %{rows: [[id]]} =
      query!(
        "INSERT INTO log_search_partitions (first_log_id, started_at) VALUES (?, ?) RETURNING id",
        [first_log_id, DateTime.to_iso8601(day_start(day))]
      )

    table = "logs_fts_#{id}"
    query!("CREATE VIRTUAL TABLE #{table} USING #{@partition_options}")
    table
  end

  defp insert_trigger(table) do
    """
    CREATE TRIGGER logs_fts_after_insert
    AFTER INSERT ON logs
    BEGIN
      INSERT INTO #{table}(rowid, search_text)
      VALUES (new.id, new.message || char(10) || coalesce(new.metadata, '{}'));
    END
    """
  end

  defp drop_partitions do
    %{rows: catalog} =
      query!(
        "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'log_search_partitions'"
      )

    if catalog != [] do
      for [id] <- query!("SELECT id FROM log_search_partitions").rows do
        query!("DROP TABLE IF EXISTS logs_fts_#{id}")
      end

      query!("DROP TABLE log_search_partitions")
    end
  end

  defp date(inserted_at) do
    {:ok, datetime, 0} = DateTime.from_iso8601(inserted_at)
    DateTime.to_date(datetime)
  end

  defp day_start(%Date{} = day), do: DateTime.new!(day, ~T[00:00:00], "Etc/UTC")

  defp transaction!(fun), do: {:ok, _result} = repo().transaction(fun, timeout: :infinity)

  defp query!(sql, params \\ []), do: repo().query!(sql, params, timeout: :infinity)
end
