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

      %{rows: [[insert_trigger], [update_trigger]]} =
        Repo.query!("""
        SELECT sql
        FROM sqlite_schema
        WHERE name IN ('logs_fts_after_insert', 'logs_fts_after_update')
        ORDER BY name
        """)

      refute insert_trigger =~ "json(new.metadata)"
      refute update_trigger =~ "json(new.metadata)"
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

    test "uses metadata keys and values as candidates while preserving JSON semantics" do
      assert {:ok, [exact, false_association, wrong_key]} =
               Logs.insert_batch("api", [
                 %{
                   "message" => "exact",
                   "metadata" => %{"request_id" => "abcdef123"}
                 },
                 %{
                   "message" => "false association",
                   "metadata" => %{"request_id" => "other", "detail" => "abcdef123"}
                 },
                 %{
                   "message" => "wrong key",
                   "metadata" => %{"trace_id" => "abcdef123"}
                 }
               ])

      force_broad_window()
      {:ok, tokens} = SearchParser.parse("request_id:abcdef123")
      assert {:fts, _match_query} = SqliteFts.strategy(tokens, nil, nil)

      ids = Logs.list_logs(search: "request_id:abcdef123") |> Enum.map(& &1.id)

      assert ids == [exact.id]
      refute false_association.id in ids
      refute wrong_key.id in ids
    end

    test "uses metadata keys as candidates for numeric comparisons" do
      assert {:ok, [fast, slow]} =
               Logs.insert_batch("api", [
                 %{"message" => "fast", "metadata" => %{"latency_ms" => 12}},
                 %{"message" => "slow", "metadata" => %{"latency_ms" => 250}}
               ])

      force_broad_window()
      {:ok, tokens} = SearchParser.parse("latency_ms:>100")
      assert {:fts, _match_query} = SqliteFts.strategy(tokens, nil, nil)

      ids = Logs.list_logs(search: "latency_ms:>100") |> Enum.map(& &1.id)
      assert ids == [slow.id]
      refute fast.id in ids
    end

    test "counts and applies FTS candidates inside the observed-time window" do
      assert {:ok, [recent]} = Logs.insert_batch("api", [%{"message" => "common-search"}])
      force_broad_window()
      {:ok, tokens} = SearchParser.parse("common-search")

      Repo.query!("""
      WITH RECURSIVE sequence(value) AS (
        SELECT 1
        UNION ALL
        SELECT value + 1 FROM sequence WHERE value <= 25000
      )
      INSERT INTO logs_fts(rowid, search_text)
      SELECT -value, 'common-search' FROM sequence
      """)

      assert :scan = SqliteFts.strategy(tokens, nil, nil)

      from = DateTime.add(DateTime.utc_now(), -1, :hour)
      assert {:fts, _match_query} = SqliteFts.strategy(tokens, from, nil)

      assert Logs.list_logs(search: "common-search", from: from) |> Enum.map(& &1.id) == [
               recent.id
             ]
    end

    test "extracts only conservative mandatory literals from positive regexes" do
      assert {:ok, [exact, wrong_order, quantified]} =
               Logs.insert_batch("api", [
                 %{"message" => "checkout request reached timeout"},
                 %{"message" => "timeout happened before checkout"},
                 %{"message" => "fooobar"}
               ])

      force_broad_window()

      {:ok, tokens} = SearchParser.parse("/checkout.*timeout/")
      assert {:fts, _match_query} = SqliteFts.strategy(tokens, nil, nil)

      ids = Logs.list_logs(search: "/checkout.*timeout/") |> Enum.map(& &1.id)
      assert ids == [exact.id]
      refute wrong_order.id in ids

      {:ok, alternation} = SearchParser.parse("/checkout|timeout/")
      assert {:fts, match_query} = SqliteFts.strategy(alternation, nil, nil)
      assert match_query =~ " OR "

      {:ok, optional_branch} = SearchParser.parse("/checkout|.*/")
      assert :scan = SqliteFts.strategy(optional_branch, nil, nil)

      {:ok, grouped} = SearchParser.parse("/(checkout).*timeout/")
      assert :scan = SqliteFts.strategy(grouped, nil, nil)

      {:ok, variable_quantifier} = SearchParser.parse("/fo+bar/")
      assert {:fts, _match_query} = SqliteFts.strategy(variable_quantifier, nil, nil)

      assert Logs.list_logs(search: "/fo+bar/") |> Enum.map(& &1.id) == [quantified.id]

      {:ok, no_safe_quantified_literal} = SearchParser.parse("/ab+c/")
      assert :scan = SqliteFts.strategy(no_safe_quantified_literal, nil, nil)
    end

    test "does not create an FTS universe from negative-only searches" do
      {:ok, negative_term} = SearchParser.parse("-timeout")
      assert :scan = SqliteFts.strategy(negative_term, nil, nil)

      {:ok, negative_regex} = SearchParser.parse("-/timeout/")
      assert :scan = SqliteFts.strategy(negative_regex, nil, nil)
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
