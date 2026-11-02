defmodule WhisperLogs.Logs.TimestampTest do
  use ExUnit.Case, async: true

  alias WhisperLogs.Logs.Timestamp

  test "normalizes every fractional precision to microseconds" do
    for {input, expected} <- [
          {"2026-11-02T03:32:37Z", ~U[2026-11-02 03:32:37.000000Z]},
          {"2026-11-02T03:32:37.2Z", ~U[2026-11-02 03:32:37.200000Z]},
          {"2026-11-02T03:32:37.27493Z", ~U[2026-11-02 03:32:37.274930Z]},
          {"2026-11-02T03:32:37.274930Z", ~U[2026-11-02 03:32:37.274930Z]},
          {"2026-11-02T03:32:37.274930999Z", ~U[2026-11-02 03:32:37.274930Z]},
          {"2026-11-02T03:32:37.5-08:00", ~U[2026-11-02 11:32:37.500000Z]},
          {"2026-11-02t03:32:37z", ~U[2026-11-02 03:32:37.000000Z]}
        ] do
      assert {:ok, datetime} = Timestamp.parse(input)
      assert DateTime.compare(datetime, expected) == :eq
      assert datetime.microsecond == expected.microsecond
    end
  end

  test "accepts leap seconds only at the end of a UTC minute 23:59" do
    assert Timestamp.parse("2016-12-31T23:59:60Z") == {:ok, ~U[2016-12-31 23:59:59.999999Z]}
    assert Timestamp.parse("2016-12-31T23:59:60.5Z") == {:ok, ~U[2016-12-31 23:59:59.999999Z]}
    assert Timestamp.parse("2016-12-31T15:59:60-08:00") == {:ok, ~U[2016-12-31 23:59:59.999999Z]}
    assert Timestamp.parse("2026-11-02T03:32:60Z") == {:error, :invalid_rfc3339}
  end

  test "rejects values the database adapters cannot store and read back" do
    assert {:ok, _} = Timestamp.parse("0000-01-01T00:00:00Z")
    assert {:ok, _} = Timestamp.parse("9999-12-31T23:59:59.999999Z")
    assert {:ok, _} = Timestamp.parse("-4713-11-24T00:00:00Z")
    assert Timestamp.parse("-4714-01-01T00:00:00Z") == {:error, :out_of_range}
    assert Timestamp.parse("9999-12-31T23:59:59-23:59") == {:error, :out_of_range}
  end

  test "rejects malformed values" do
    for input <- [
          "",
          "garbage",
          "2026-02-30T00:00:00Z",
          "2026-11-02",
          <<0xFF>>,
          "2026-11-02T03:32:37Z\0"
        ] do
      assert Timestamp.parse(input) == {:error, :invalid_rfc3339}
    end
  end
end
