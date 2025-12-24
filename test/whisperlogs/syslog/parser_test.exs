defmodule WhisperLogs.Syslog.ParserTest do
  use ExUnit.Case, async: true

  alias WhisperLogs.Syslog.Parser

  # ===== RFC 3164 (BSD) Format Tests =====

  describe "RFC 3164 (BSD) format" do
    test "parses simple message" do
      message = "<34>Oct 11 22:14:15 mymachine su: 'su root' failed"

      {:ok, result} = Parser.parse(message)

      assert result["level"] == "error"
      assert result["message"] == "su: 'su root' failed"
      assert result["metadata"]["hostname"] == "mymachine"
      assert result["metadata"]["facility"] == "auth"
      assert result["metadata"]["format"] == "rfc3164"
    end

    test "extracts correct facility from PRI" do
      # PRI 34 = facility 4 (auth) * 8 + severity 2 (critical)
      message = "<34>Oct 11 22:14:15 host test"
      {:ok, result} = Parser.parse(message)
      assert result["metadata"]["facility"] == "auth"

      # PRI 0 = facility 0 (kern) * 8 + severity 0 (emergency)
      message = "<0>Oct 11 22:14:15 host test"
      {:ok, result} = Parser.parse(message)
      assert result["metadata"]["facility"] == "kern"

      # PRI 134 = facility 16 (local0) * 8 + severity 6 (info)
      message = "<134>Oct 11 22:14:15 host test"
      {:ok, result} = Parser.parse(message)
      assert result["metadata"]["facility"] == "local0"
    end

    test "extracts correct severity and maps to level" do
      # severity 0-3 (emergency, alert, critical, error) -> "error"
      {:ok, result} = Parser.parse("<0>Oct 11 22:14:15 host test")
      assert result["level"] == "error"

      {:ok, result} = Parser.parse("<3>Oct 11 22:14:15 host test")
      assert result["level"] == "error"

      # severity 4 (warning) -> "warning"
      {:ok, result} = Parser.parse("<4>Oct 11 22:14:15 host test")
      assert result["level"] == "warning"

      # severity 5-6 (notice, info) -> "info"
      {:ok, result} = Parser.parse("<5>Oct 11 22:14:15 host test")
      assert result["level"] == "info"

      {:ok, result} = Parser.parse("<6>Oct 11 22:14:15 host test")
      assert result["level"] == "info"

      # severity 7 (debug) -> "debug"
      {:ok, result} = Parser.parse("<7>Oct 11 22:14:15 host test")
      assert result["level"] == "debug"
    end

    test "handles single-digit days" do
      message = "<34>Oct  5 22:14:15 host test message"

      {:ok, result} = Parser.parse(message)

      assert result["message"] == "test message"
      assert result["metadata"]["hostname"] == "host"
    end

    test "handles missing hostname - returns entire rest as message" do
      # When the format is not standard, parser returns the whole rest as message
      message = "<34>not a valid header"

      {:ok, result} = Parser.parse(message)

      # Should still parse PRI and return the rest
      assert result["level"] == "error"
      assert result["message"] == "not a valid header"
    end

    test "returns error for malformed input" do
      # No PRI
      assert Parser.parse("just some text") == {:error, :invalid_format}

      # Empty string
      assert Parser.parse("") == {:error, :invalid_format}
    end
  end

  # ===== RFC 5424 (IETF) Format Tests =====

  describe "RFC 5424 (IETF) format" do
    test "parses full message" do
      message =
        "<34>1 2003-10-11T22:14:15.003Z mymachine.example.com su - ID47 - 'su root' failed"

      {:ok, result} = Parser.parse(message)

      assert result["level"] == "error"
      assert result["message"] == "'su root' failed"
      assert result["metadata"]["hostname"] == "mymachine.example.com"
      assert result["metadata"]["appname"] == "su"
      assert result["metadata"]["facility"] == "auth"
      assert result["metadata"]["format"] == "rfc5424"
    end

    test "extracts appname and procid" do
      message = "<165>1 2003-10-11T22:14:15.003Z mymachine app 1234 MSG01 - Test"

      {:ok, result} = Parser.parse(message)

      assert result["metadata"]["appname"] == "app"
      assert result["metadata"]["procid"] == "1234"
    end

    test "handles structured data" do
      message =
        "<165>1 2003-10-11T22:14:15.003Z host app - - [exampleSDID@123 key=\"value\"] Test msg"

      {:ok, result} = Parser.parse(message)

      assert result["metadata"]["structured_data"] =~ "exampleSDID@123"
    end

    test "handles nil fields indicated by -" do
      message = "<165>1 2003-10-11T22:14:15.003Z - - - - - Test message"

      {:ok, result} = Parser.parse(message)

      assert result["message"] == "Test message"
      # Nil fields should not be included in metadata
      refute Map.has_key?(result["metadata"], "hostname")
      refute Map.has_key?(result["metadata"], "appname")
      refute Map.has_key?(result["metadata"], "procid")
    end

    test "preserves ISO8601 timestamp" do
      message = "<165>1 2003-10-11T22:14:15.003Z host app - - - Test"

      {:ok, result} = Parser.parse(message)

      assert result["timestamp"] == "2003-10-11T22:14:15.003Z"
    end
  end

  # ===== Format Detection Tests =====

  describe "format detection" do
    test "detects RFC 5424 by version number" do
      # RFC 5424 has version after PRI
      message = "<34>1 2003-10-11T22:14:15.003Z host app - - - Test"

      {:ok, result} = Parser.parse(message)

      assert result["metadata"]["format"] == "rfc5424"
    end

    test "falls back to RFC 3164 for no version" do
      # RFC 3164 has timestamp directly after PRI
      message = "<34>Oct 11 22:14:15 host message"

      {:ok, result} = Parser.parse(message)

      assert result["metadata"]["format"] == "rfc3164"
    end
  end

  # ===== Facility Mapping Tests =====

  describe "facility mapping" do
    test "maps common facilities correctly" do
      facilities = [
        {0, "kern"},
        {1, "user"},
        {2, "mail"},
        {3, "daemon"},
        {4, "auth"},
        {5, "syslog"},
        {16, "local0"},
        {17, "local1"},
        {18, "local2"},
        {19, "local3"},
        {20, "local4"},
        {21, "local5"},
        {22, "local6"},
        {23, "local7"}
      ]

      for {fac_num, fac_name} <- facilities do
        # PRI = facility * 8 + severity (use severity 6 = info)
        pri = fac_num * 8 + 6
        message = "<#{pri}>Oct 11 22:14:15 host test"

        {:ok, result} = Parser.parse(message)
        assert result["metadata"]["facility"] == fac_name
      end
    end
  end

  # ===== Edge Cases =====

  describe "edge cases" do
    test "handles whitespace in message" do
      # Parser trims trailing whitespace from input (standard syslog behavior)
      message = "<34>Oct 11 22:14:15 host test:   message with   spaces  "

      {:ok, result} = Parser.parse(message)

      # Internal whitespace is preserved, but trailing is trimmed
      assert result["message"] == "test:   message with   spaces"
    end

    test "handles special characters in message" do
      message = "<34>Oct 11 22:14:15 host test: <tag> &amp; \"quoted\""

      {:ok, result} = Parser.parse(message)

      assert result["message"] =~ "<tag>"
      assert result["message"] =~ "&amp;"
    end

    test "handles very long messages" do
      long_text = String.duplicate("x", 10000)
      message = "<34>Oct 11 22:14:15 host #{long_text}"

      {:ok, result} = Parser.parse(message)

      assert String.length(result["message"]) == 10000
    end

    test "handles newlines in message" do
      message = "<34>Oct 11 22:14:15 host test: line1\nline2\nline3"

      {:ok, result} = Parser.parse(message)

      assert result["message"] =~ "line1\nline2\nline3"
    end
  end
end
