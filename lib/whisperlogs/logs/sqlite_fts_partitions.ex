defmodule WhisperLogs.Logs.SqliteFtsPartitions do
  @moduledoc """
  The SQLite full-text index, split into one FTS5 table per UTC day.

  New logs are indexed only into the newest partition, through the insert trigger,
  so FTS5 merges stay within one day's data and the writer lock they hold stays
  short. Retention drops a partition whole once none of its logs remain, rather
  than deleting from the index row by row. Logs are never updated or deleted
  individually except by retention, so the partitions need no other triggers.
  """

  require Logger

  alias WhisperLogs.DbAdapter
  alias WhisperLogs.Repo

  # Dropping a partition holds the writer lock for up to about a second. Waiting
  # writers retry with backoff sleeps of up to 100 ms, so a shorter pause between
  # drops would let a catch-up run of many drops starve them past busy_timeout.
  @drop_pause_ms 200

  @doc """
  Returns the partitions' table names, oldest first.
  """
  def table_names do
    Repo.query!("SELECT id FROM log_search_partitions ORDER BY id").rows
    |> Enum.map(fn [id] -> table_name(id) end)
  end

  @doc """
  Starts a new partition when the newest one began before `now`'s UTC day.
  """
  def rotate(%DateTime{} = now) do
    day_start = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")

    {:ok, :ok} =
      DbAdapter.write_transaction(fn ->
        %{rows: [[started_at]]} =
          Repo.query!("SELECT started_at FROM log_search_partitions ORDER BY id DESC LIMIT 1")

        {:ok, started_at, 0} = DateTime.from_iso8601(started_at)

        if DateTime.compare(started_at, day_start) == :lt do
          start_partition!(day_start)

          Logger.info(
            "Started SQLite search partition for #{Date.to_iso8601(DateTime.to_date(now))}"
          )
        end

        :ok
      end)

    :ok
  end

  @doc """
  Drops each partition, except the newest, whose logs have all been deleted.
  """
  def drop_emptied do
    %{rows: partitions} =
      Repo.query!("SELECT id, first_log_id FROM log_search_partitions ORDER BY id")

    %{rows: [[oldest_log_id]]} = Repo.query!("SELECT min(id) FROM logs")

    partitions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.take_while(fn [_partition, [_next_id, next_first_log_id]] ->
      is_nil(oldest_log_id) or oldest_log_id >= next_first_log_id
    end)
    |> Enum.each(fn [[id, _first_log_id], _next] ->
      {:ok, :ok} =
        DbAdapter.write_transaction(fn ->
          Repo.query!("DROP TABLE #{table_name(id)}")
          Repo.query!("DELETE FROM log_search_partitions WHERE id = ?", [id])
          :ok
        end)

      Process.sleep(@drop_pause_ms)
    end)
  end

  defp start_partition!(%DateTime{} = started_at) do
    %{rows: [[first_log_id]]} =
      Repo.query!("SELECT coalesce((SELECT seq FROM sqlite_sequence WHERE name = 'logs'), 0) + 1")

    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO log_search_partitions (first_log_id, started_at) VALUES (?, ?) RETURNING id",
        [first_log_id, DateTime.to_iso8601(started_at)]
      )

    table = table_name(id)

    Repo.query!(
      "CREATE VIRTUAL TABLE #{table} USING fts5(search_text, content='', columnsize=0, detail=none, tokenize='trigram')"
    )

    Repo.query!("DROP TRIGGER logs_fts_after_insert")

    Repo.query!("""
    CREATE TRIGGER logs_fts_after_insert
    AFTER INSERT ON logs
    BEGIN
      INSERT INTO #{table}(rowid, search_text)
      VALUES (new.id, new.message || char(10) || coalesce(new.metadata, '{}'));
    END
    """)
  end

  defp table_name(id) when is_integer(id), do: "logs_fts_#{id}"
end
