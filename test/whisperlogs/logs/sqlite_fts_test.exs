if WhisperLogs.DbAdapter.sqlite?() do
  defmodule WhisperLogs.Logs.SqliteFtsTest do
    use WhisperLogs.DataCase, async: false

    alias WhisperLogs.Logs
    alias WhisperLogs.Logs.{Log, LogVolumeRollup, SearchParser, SqliteFts}

    test "synchronizes FTS entries when logs are inserted, updated, and deleted" do
      assert {:ok, [log]} = Logs.insert_batch("api", [%{"message" => "needle-one"}])
      assert indexed?(log.id, ~s("nee" AND "eed" AND "edl" AND "dle"))

      {1, nil} =
        Log
        |> where([l], l.id == ^log.id)
        |> Repo.update_all(set: [message: "replacement-two"])

      refute indexed?(log.id, ~s("nee" AND "eed" AND "edl" AND "dle"))
      assert indexed?(log.id, ~s("rep" AND "epl" AND "pla"))

      {1, nil} = Log |> where([l], l.id == ^log.id) |> Repo.delete_all()
      refute indexed?(log.id, ~s("rep" AND "epl" AND "pla"))
    end

    test "uses FTS for selective broad searches and preserves exact substring semantics" do
      assert {:ok, [exact, false_positive, metadata_match]} =
               Logs.insert_batch("api", [
                 %{"message" => "contains abcd here"},
                 %{"message" => "contains abc then bcd but not the substring"},
                 %{"message" => "metadata", "metadata" => %{"detail" => "abcd"}}
               ])

      force_broad_window()
      {:ok, tokens} = SearchParser.parse("abcd")
      assert {:fts, _match_query} = SqliteFts.strategy(tokens, nil, nil)

      ids = Logs.list_logs(search: "abcd", limit: 100) |> Enum.map(& &1.id)

      assert exact.id in ids
      assert metadata_match.id in ids
      refute false_positive.id in ids

      assert Logs.count_matches("abcd", 31 * 86_400) == 2
      assert %{hour: 2, day: 2, week: 2} = Logs.preview_counts("abcd")
    end

    test "keeps narrow windows, short terms, and common terms on ordered scans" do
      assert {:ok, [_log]} = Logs.insert_batch("api", [%{"message" => "common-search"}])
      {:ok, common_tokens} = SearchParser.parse("common-search")

      assert :scan =
               SqliteFts.strategy(
                 common_tokens,
                 DateTime.add(DateTime.utc_now(), -3, :hour),
                 nil
               )

      force_broad_window()
      assert :scan = SqliteFts.strategy([{:term, "ok"}], nil, nil)

      Repo.query!("""
      WITH RECURSIVE sequence(value) AS (
        SELECT 1
        UNION ALL
        SELECT value + 1 FROM sequence WHERE value <= 25000
      )
      INSERT INTO logs_fts(rowid, search_text)
      SELECT -value, 'common-search' FROM sequence
      """)

      assert :scan = SqliteFts.strategy(common_tokens, nil, nil)
    end

    defp force_broad_window do
      {count, nil} = Repo.update_all(LogVolumeRollup, set: [log_count: 50_001])
      assert count > 0
    end

    defp indexed?(id, match_query) do
      %{rows: [[found]]} =
        Repo.query!(
          "SELECT EXISTS(SELECT 1 FROM logs_fts WHERE rowid = ? AND logs_fts MATCH ?)",
          [id, match_query]
        )

      found == 1
    end
  end
end
