defmodule WhisperLogsWeb.LogsLiveTest do
  use WhisperLogsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WhisperLogs.LogsFixtures

  alias WhisperLogs.Accounts.User
  alias WhisperLogs.Logs
  alias WhisperLogs.Repo

  # In SQLite mode, a local@localhost user is expected to exist
  # This setup ensures it exists for all tests
  setup %{conn: conn} do
    user = ensure_local_user()
    scope = WhisperLogs.Accounts.Scope.for_user(user)
    {:ok, conn: log_in_user(conn, user), user: user, scope: scope}
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
          inserted_at: now,
          updated_at: now
        })
        |> Repo.insert!()

      user ->
        user
    end
  end

  defp insert_events(source, events) do
    events
    |> Enum.chunk_every(100)
    |> Enum.flat_map(fn chunk ->
      {:ok, inserted} = Logs.insert_batch(source, chunk)
      inserted
    end)
  end

  # Authentication is enforced identically on both database adapters.

  describe "mount and render" do
    test "renders logs page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      html = render_async(lv)

      # Check for filter form elements
      assert html =~ "filters-form"
      assert html =~ "Last 3h"
    end

    test "renders empty state when no logs", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      html = render_async(lv)

      assert html =~ "No logs yet"
      assert html =~ "Start sending logs"
    end

    test "displays logs when present", %{conn: conn} do
      _log = log_fixture("test-source", message: "Hello from test")

      {:ok, lv, _html} = live(conn, ~p"/")
      html = render_async(lv)

      assert html =~ "Hello from test"
      assert html =~ "test-source"
    end

    test "shows source in filter dropdown when logs exist", %{conn: conn} do
      _log = log_fixture("my-app-logs", message: "Test message")

      {:ok, lv, _html} = live(conn, ~p"/")
      html = render_async(lv)

      assert html =~ "my-app-logs"
    end

    test "backfills the initial 100-row paint and retains logs arriving during hydration", %{
      conn: conn
    } do
      events = Enum.map(1..150, &%{"message" => "hydration log #{&1}"})
      assert {:ok, inserted} = Logs.insert_batch("hydration-source", events)

      {:ok, lv, _html} = live(conn, ~p"/?t=30d")
      new_log = log_fixture("hydration-source", message: "arrived during hydration")

      _ = :sys.get_state(lv.pid)
      send(lv.pid, :flush_log_buffer)
      render_async(lv)

      assert has_element?(lv, "#logs-#{List.first(inserted).id}")
      assert has_element?(lv, "#logs-#{List.last(inserted).id}")
      assert has_element?(lv, "#logs-#{new_log.id}")
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
      render_async(lv)

      # Uncheck "debug" level
      lv
      |> element("#filters-form")
      |> render_change(%{"levels" => ["info", "warning", "error"]})

      html = render_async(lv)

      # Debug should be excluded
      refute html =~ "Debug message"
      assert html =~ "Info message"
      assert html =~ "Warning message"
      assert html =~ "Error message"
    end

    test "filters by source", %{conn: conn} do
      _other_log = log_fixture("other-source", message: "Other source log")

      {:ok, lv, _html} = live(conn, ~p"/")
      render_async(lv)

      lv
      |> element("#filters-form")
      |> render_change(%{"source" => "test-source"})

      html = render_async(lv)

      assert html =~ "Debug message"
      refute html =~ "Other source log"
    end

    test "clears filters", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      render_async(lv)

      # Apply a filter first
      lv
      |> element("#filters-form")
      |> render_change(%{"levels" => ["error"]})

      render_async(lv)

      # Clear filters
      lv
      |> element("button", "Clear")
      |> render_click()

      html = render_async(lv)

      # All levels should be shown again
      assert html =~ "Debug message"
      assert html =~ "Info message"
      assert html =~ "Warning message"
      assert html =~ "Error message"
    end

    test "ignores stale async results when filters change rapidly", %{conn: conn} do
      old_result = log_fixture("test-source", message: "stale-filter-result")
      current_result = log_fixture("test-source", message: "current-filter-result")

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("#filters-form")
      |> render_change(%{"search" => "stale-filter-result"})

      lv
      |> element("#filters-form")
      |> render_change(%{"search" => "current-filter-result"})

      render_async(lv)

      refute has_element?(lv, "#logs-#{old_result.id}")
      assert has_element?(lv, "#logs-#{current_result.id}")
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
      render_async(lv)

      lv
      |> element("#filters-form")
      |> render_change(%{"search" => "timeout"})

      html = render_async(lv)

      assert html =~ "Connection timeout error"
      refute html =~ "User login successful"
    end

    test "searches by metadata key:value", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      render_async(lv)

      lv
      |> element("#filters-form")
      |> render_change(%{"search" => "user_id:123"})

      html = render_async(lv)

      assert html =~ "Request processed"
      refute html =~ "User login successful"
    end

    test "excludes terms with - prefix", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      render_async(lv)

      lv
      |> element("#filters-form")
      |> render_change(%{"search" => "-timeout"})

      html = render_async(lv)

      refute html =~ "Connection timeout error"
      assert html =~ "User login successful"
      assert html =~ "Request processed"
    end
  end

  describe "staged navigation" do
    test "jump to latest paints the first page before hydrating the full window", %{conn: conn} do
      events = Enum.map(1..150, &%{"message" => "jump hydration log #{&1}"})
      assert {:ok, _inserted} = Logs.insert_batch("jump-source", events)

      {:ok, lv, _html} = live(conn, ~p"/?t=30d")
      render_async(lv)

      render_click(lv, "far-from-bottom")
      assert has_element?(lv, "#jump-to-latest")

      lv
      |> element("#jump-to-latest")
      |> render_click()

      assert_push_event(lv, "force-scroll-bottom", %{}, 1_000)
      render_async(lv)

      [newest | _] = logs = Logs.list_logs(sources: ["jump-source"], limit: 150)
      oldest = List.last(logs)

      assert has_element?(lv, "#logs-#{newest.id}")
      assert has_element?(lv, "#logs-#{oldest.id}")
    end

    test "view in context paints 100 centered rows then hydrates outward", %{conn: conn} do
      events = Enum.map(1..520, &%{"message" => "context hydration log #{&1}"})
      assert length(insert_events("context-source", events)) == 520

      ordered_logs = Logs.list_logs(sources: ["context-source"], limit: 520)
      target = Enum.at(ordered_logs, 260)
      target_id = Integer.to_string(target.id)
      hydrated_newer_edge = Enum.at(ordered_logs, 10)
      hydrated_older_log = Enum.at(ordered_logs, 450)

      {:ok, lv, _html} = live(conn, ~p"/?t=30d")
      render_async(lv)

      lv
      |> element("#filters-form")
      |> render_change(%{"search" => target.message})

      render_async(lv)

      lv
      |> element("#view-in-context-#{target.id}")
      |> render_click()

      assert_push_event(lv, "scroll-to-log", %{log_id: ^target_id}, 1_000)
      render_async(lv)

      assert has_element?(lv, "#logs-#{target.id}")
      assert has_element?(lv, "#logs-#{hydrated_newer_edge.id}")
      assert has_element?(lv, "#logs-#{hydrated_older_log.id}")
    end

    test "scroll to time paints the nearby page then hydrates outward", %{conn: conn} do
      events = Enum.map(1..320, &%{"message" => "time hydration log #{&1}"})
      assert length(insert_events("time-source", events)) == 320

      ordered_logs = Logs.list_logs(sources: ["time-source"], limit: 320)
      target_time = List.last(ordered_logs).inserted_at
      local_time = DateTime.shift_zone!(target_time, "America/Los_Angeles")

      {:ok, lv, _html} = live(conn, ~p"/?t=30d")
      render_async(lv)

      lv
      |> element("#scroll-to-date")
      |> render_change(%{"scroll_to_date" => Date.to_iso8601(local_time)})

      lv
      |> element("#scroll-to-time")
      |> render_change(%{"scroll_to_time" => Calendar.strftime(local_time, "%H:%M:%S")})

      lv
      |> element("#scroll-to-submit")
      |> render_click()

      assert_push_event(lv, "scroll-to-log", %{log_id: _log_id}, 1_000)
      render_async(lv)

      hydrated_log = Enum.at(ordered_logs, 100)
      assert has_element?(lv, "#logs-#{hydrated_log.id}")
    end
  end

  describe "live tail" do
    test "toggles live tail on/off", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      html = render_async(lv)

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
      render_async(lv)

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

      {:ok, lv, _html} = live(conn, ~p"/")
      html = render_async(lv)
      assert html =~ "Recent log"

      # Change to 24h - should still show the log
      lv
      |> element("#filters-form")
      |> render_change(%{"time_range" => "24h"})

      html = render_async(lv)
      assert html =~ "Recent log"
    end
  end
end
