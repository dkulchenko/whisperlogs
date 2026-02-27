defmodule WhisperLogs.Logs.SearchParserTest do
  use ExUnit.Case, async: true

  alias WhisperLogs.Logs.SearchParser

  describe "level: filter parsing" do
    test "parses level:debug" do
      assert {:ok, [{:level_filter, "debug"}]} = SearchParser.parse("level:debug")
    end

    test "normalizes level aliases case-insensitively" do
      # Debug variants
      assert {:ok, [{:level_filter, "debug"}]} = SearchParser.parse("level:dbg")
      assert {:ok, [{:level_filter, "debug"}]} = SearchParser.parse("level:DBG")
      assert {:ok, [{:level_filter, "debug"}]} = SearchParser.parse("level:DEBUG")

      # Info variants
      assert {:ok, [{:level_filter, "info"}]} = SearchParser.parse("level:inf")
      assert {:ok, [{:level_filter, "info"}]} = SearchParser.parse("level:INF")
      assert {:ok, [{:level_filter, "info"}]} = SearchParser.parse("level:INFO")

      # Warning variants
      assert {:ok, [{:level_filter, "warning"}]} = SearchParser.parse("level:warn")
      assert {:ok, [{:level_filter, "warning"}]} = SearchParser.parse("level:WRN")
      assert {:ok, [{:level_filter, "warning"}]} = SearchParser.parse("level:WARN")
      assert {:ok, [{:level_filter, "warning"}]} = SearchParser.parse("level:WARNING")
      assert {:ok, [{:level_filter, "warning"}]} = SearchParser.parse("level:wrn")

      # Error variants
      assert {:ok, [{:level_filter, "error"}]} = SearchParser.parse("level:err")
      assert {:ok, [{:level_filter, "error"}]} = SearchParser.parse("level:ERR")
      assert {:ok, [{:level_filter, "error"}]} = SearchParser.parse("level:ERROR")
    end

    test "parses excluded level" do
      assert {:ok, [{:exclude_level_filter, "debug"}]} = SearchParser.parse("-level:debug")
      assert {:ok, [{:exclude_level_filter, "info"}]} = SearchParser.parse("-level:INF")
    end

    test "returns empty for unknown level" do
      assert {:ok, []} = SearchParser.parse("level:unknown")
      assert {:ok, []} = SearchParser.parse("level:trace")
    end

    test "key is case insensitive" do
      assert {:ok, [{:level_filter, "error"}]} = SearchParser.parse("LEVEL:error")
      assert {:ok, [{:level_filter, "error"}]} = SearchParser.parse("Level:error")
    end
  end

  describe "timestamp: filter parsing" do
    test "parses timestamp with gt operator and ISO date" do
      {:ok, [{:timestamp_filter, :gt, dt}]} = SearchParser.parse("timestamp:>2025-08-12")
      assert dt.year == 2025
      assert dt.month == 8
      assert dt.day == 12
    end

    test "parses timestamp with gte operator" do
      {:ok, [{:timestamp_filter, :gte, dt}]} = SearchParser.parse("timestamp:>=2025-08-12")
      assert dt.year == 2025
    end

    test "parses timestamp with lt operator" do
      {:ok, [{:timestamp_filter, :lt, dt}]} = SearchParser.parse("timestamp:<2025-01-01")
      assert dt.year == 2025
      assert dt.month == 1
    end

    test "parses timestamp with lte operator" do
      {:ok, [{:timestamp_filter, :lte, dt}]} = SearchParser.parse("timestamp:<=2025-12-31")
      assert dt.year == 2025
      assert dt.month == 12
    end

    test "parses timestamp with eq operator (default)" do
      {:ok, [{:timestamp_filter, :eq, dt}]} = SearchParser.parse("timestamp:2025-06-15")
      assert dt.year == 2025
      assert dt.month == 6
    end

    test "parses relative timestamp 'today'" do
      {:ok, [{:timestamp_filter, :gte, dt}]} = SearchParser.parse("timestamp:>=today")
      today = Date.utc_today()
      assert Date.compare(DateTime.to_date(dt), today) == :eq
      assert dt.hour == 0
      assert dt.minute == 0
      assert dt.second == 0
    end

    test "parses relative timestamp 'yesterday'" do
      {:ok, [{:timestamp_filter, :gt, dt}]} = SearchParser.parse("timestamp:>yesterday")
      yesterday = Date.add(Date.utc_today(), -1)
      assert Date.compare(DateTime.to_date(dt), yesterday) == :eq
    end

    test "parses relative offset -1h" do
      before = DateTime.utc_now()
      {:ok, [{:timestamp_filter, :gt, dt}]} = SearchParser.parse("timestamp:>-1h")

      # dt should be roughly 1 hour ago (allow some tolerance for test execution)
      diff = DateTime.diff(before, dt, :minute)
      assert diff >= 59 and diff <= 61
    end

    test "parses relative offset -7d" do
      before = DateTime.utc_now()
      {:ok, [{:timestamp_filter, :gte, dt}]} = SearchParser.parse("timestamp:>=-7d")

      # dt should be roughly 7 days ago
      diff = DateTime.diff(before, dt, :day)
      assert diff >= 6 and diff <= 8
    end

    test "parses relative offset -30m" do
      before = DateTime.utc_now()
      {:ok, [{:timestamp_filter, :gt, dt}]} = SearchParser.parse("timestamp:>-30m")

      diff = DateTime.diff(before, dt, :minute)
      assert diff >= 29 and diff <= 31
    end

    test "parses relative offset -2w" do
      before = DateTime.utc_now()
      {:ok, [{:timestamp_filter, :gt, dt}]} = SearchParser.parse("timestamp:>-2w")

      diff = DateTime.diff(before, dt, :day)
      assert diff >= 13 and diff <= 15
    end

    test "parses excluded timestamp" do
      {:ok, [{:exclude_timestamp_filter, :lt, _dt}]} =
        SearchParser.parse("-timestamp:<2025-01-01")
    end

    test "returns empty for invalid timestamp" do
      assert {:ok, []} = SearchParser.parse("timestamp:>invalid")
      assert {:ok, []} = SearchParser.parse("timestamp:>abc123")
    end

    test "key is case insensitive" do
      {:ok, [{:timestamp_filter, :gt, _dt}]} = SearchParser.parse("TIMESTAMP:>2025-01-01")
      {:ok, [{:timestamp_filter, :gt, _dt}]} = SearchParser.parse("Timestamp:>2025-01-01")
    end
  end

  describe "source: filter parsing" do
    test "parses source filter" do
      assert {:ok, [{:source_filter, "prod"}]} = SearchParser.parse("source:prod")
    end

    test "parses source filter with complex value" do
      assert {:ok, [{:source_filter, "production-api"}]} =
               SearchParser.parse("source:production-api")
    end

    test "parses excluded source" do
      assert {:ok, [{:exclude_source_filter, "test"}]} = SearchParser.parse("-source:test")
    end

    test "key is case insensitive" do
      assert {:ok, [{:source_filter, "prod"}]} = SearchParser.parse("SOURCE:prod")
      assert {:ok, [{:source_filter, "prod"}]} = SearchParser.parse("Source:prod")
    end
  end

  describe "negated phrase parsing" do
    test "parses negated phrase" do
      assert {:ok, [{:exclude_phrase, "easypost message"}]} =
               SearchParser.parse("-\"easypost message\"")
    end

    test "parses negated single-word phrase" do
      assert {:ok, [{:exclude_phrase, "error"}]} = SearchParser.parse("-\"error\"")
    end

    test "ignores empty negated phrase" do
      assert {:ok, []} = SearchParser.parse("-\"\"")
    end

    test "combines with other tokens" do
      {:ok, tokens} = SearchParser.parse("level:warn -\"easypost message\"")
      assert length(tokens) == 2
      assert Enum.any?(tokens, fn t -> match?({:level_filter, "warning"}, t) end)
      assert Enum.any?(tokens, fn t -> match?({:exclude_phrase, "easypost message"}, t) end)
    end
  end

  describe "combined queries" do
    test "parses multiple pseudo-metadata filters" do
      {:ok, tokens} = SearchParser.parse("level:error timestamp:>-1h source:prod")
      assert length(tokens) == 3
      assert Enum.any?(tokens, fn t -> match?({:level_filter, "error"}, t) end)
      assert Enum.any?(tokens, fn t -> match?({:timestamp_filter, :gt, _}, t) end)
      assert Enum.any?(tokens, fn t -> match?({:source_filter, "prod"}, t) end)
    end

    test "mixes pseudo and regular metadata" do
      {:ok, tokens} = SearchParser.parse("level:error user_id:123")
      assert length(tokens) == 2
      assert Enum.any?(tokens, fn t -> match?({:level_filter, "error"}, t) end)
      assert Enum.any?(tokens, fn t -> match?({:metadata, "user_id", :eq, "123"}, t) end)
    end

    test "parses complex query with exclusions" do
      {:ok, tokens} = SearchParser.parse("error -level:debug timestamp:>=today -source:test")
      assert length(tokens) == 4
      assert Enum.any?(tokens, fn t -> match?({:term, "error"}, t) end)
      assert Enum.any?(tokens, fn t -> match?({:exclude_level_filter, "debug"}, t) end)
      assert Enum.any?(tokens, fn t -> match?({:timestamp_filter, :gte, _}, t) end)
      assert Enum.any?(tokens, fn t -> match?({:exclude_source_filter, "test"}, t) end)
    end
  end
end
