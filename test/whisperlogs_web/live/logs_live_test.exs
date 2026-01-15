defmodule WhisperLogsWeb.LogsLiveTest do
  use WhisperLogsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WhisperLogs.LogsFixtures

  alias WhisperLogs.Accounts.User
  alias WhisperLogs.Repo

  # In SQLite mode, a local@localhost user is expected to exist
  # This setup ensures it exists for all tests
  setup do
    ensure_local_user()
    :ok
  end

  defp ensure_local_user do
    import Ecto.Query

    case Repo.one(from u in User, where: u.email == "local@localhost", limit: 1) do
      nil ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        %User{}
        |> Ecto.Changeset.change(%{
          email: "local@localhost",
          is_admin: true,
          confirmed_at: now,
          inserted_at: now,
          updated_at: now
        })
        |> Repo.insert!()

      user ->
        user
    end
  end

  # Note: In PostgreSQL mode, unauthenticated users are redirected.
  # In SQLite mode (single-user), authentication is bypassed.
  # These tests run in SQLite mode.

  describe "mount and render" do
    test "renders logs page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      # Check for filter form elements
      assert html =~ "filters-form"
      assert html =~ "Last 3h"
    end

    test "renders empty state when no logs", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "No logs yet"
      assert html =~ "Start sending logs"
    end

    test "displays logs when present", %{conn: conn} do
      _log = log_fixture("test-source", message: "Hello from test")

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Hello from test"
      assert html =~ "test-source"
    end

    test "shows source in filter dropdown when logs exist", %{conn: conn} do
      _log = log_fixture("my-app-logs", message: "Test message")

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "my-app-logs"
    end
  end

  describe "filtering" do
    setup do
      # Create logs with different levels
      _debug_log = log_fixture("test-source", level: "debug", message: "Debug message")
      _info_log = log_fixture("test-source", level: "info", message: "Info message")
      _warning_log = log_fixture("test-source", level: "warning", message: "Warning message")
      _error_log = log_fixture("test-source", level: "error", message: "Error message")
      :ok
    end

    test "filters by level when checkbox clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      # Uncheck "debug" level
      html =
        lv
        |> element("#filters-form")
        |> render_change(%{"levels" => ["info", "warning", "error"]})

      # Debug should be excluded
      refute html =~ "Debug message"
      assert html =~ "Info message"
      assert html =~ "Warning message"
      assert html =~ "Error message"
    end

    test "filters by source", %{conn: conn} do
      _other_log = log_fixture("other-source", message: "Other source log")

      {:ok, lv, _html} = live(conn, ~p"/")

      html =
        lv
        |> element("#filters-form")
        |> render_change(%{"source" => "test-source"})

      assert html =~ "Debug message"
      refute html =~ "Other source log"
    end

    test "clears filters", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      # Apply a filter first
      lv
      |> element("#filters-form")
      |> render_change(%{"levels" => ["error"]})

      # Clear filters
      html =
        lv
        |> element("button", "Clear")
        |> render_click()

      # All levels should be shown again
      assert html =~ "Debug message"
      assert html =~ "Info message"
      assert html =~ "Warning message"
      assert html =~ "Error message"
    end
  end

  describe "search" do
    setup do
      # Create logs with different content
      _log1 = log_fixture("test-source", message: "Connection timeout error")
      _log2 = log_fixture("test-source", message: "User login successful")

      _log3 =
        log_fixture("test-source",
          message: "Request processed",
          metadata: %{"user_id" => "123"}
        )

      :ok
    end

    test "searches by message content", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      html =
        lv
        |> element("#filters-form")
        |> render_change(%{"search" => "timeout"})

      assert html =~ "Connection timeout error"
      refute html =~ "User login successful"
    end

    test "searches by metadata key:value", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      html =
        lv
        |> element("#filters-form")
        |> render_change(%{"search" => "user_id:123"})

      assert html =~ "Request processed"
      refute html =~ "User login successful"
    end

    test "excludes terms with - prefix", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      html =
        lv
        |> element("#filters-form")
        |> render_change(%{"search" => "-timeout"})

      refute html =~ "Connection timeout error"
      assert html =~ "User login successful"
      assert html =~ "Request processed"
    end
  end

  describe "live tail" do
    test "toggles live tail on/off", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/")

      # Initially live tail is on
      assert html =~ "Live"

      # Click to toggle off
      html = render_click(lv, "toggle_live_tail")
      assert html =~ "Paused"

      # Click to toggle back on
      html = render_click(lv, "toggle_live_tail")
      assert html =~ "Live"
    end

    test "receives new logs via PubSub when live tail is on", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      # Create a new log - this should trigger PubSub broadcast
      _new_log = log_fixture("test-source", message: "New real-time log")

      # Force flush of the log buffer (logs are batched for performance)
      send(lv.pid, :flush_log_buffer)

      # Re-render to see update
      html = render(lv)
      assert html =~ "New real-time log"
    end
  end

  describe "time range" do
    test "changes time range filter", %{conn: conn} do
      # Create a recent log
      _recent = log_fixture("test-source", message: "Recent log")

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "Recent log"

      # Change to 24h - should still show the log
      html =
        lv
        |> element("#filters-form")
        |> render_change(%{"time_range" => "24h"})

      assert html =~ "Recent log"
    end
  end
end
