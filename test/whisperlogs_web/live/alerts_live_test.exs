defmodule WhisperLogsWeb.AlertsLiveTest do
  use WhisperLogsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WhisperLogs.AlertsFixtures

  alias WhisperLogs.Accounts.User
  alias WhisperLogs.Repo

  # Suppress logs from async Tasks that may outlive the test
  @moduletag capture_log: true

  # In SQLite mode, a local@localhost user is expected to exist
  setup do
    user = ensure_local_user()
    {:ok, user: user}
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

  describe "mount and render" do
    test "renders alerts page with empty state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/alerts")

      assert html =~ "Alerts"
      assert html =~ "No alerts yet"
      assert html =~ "Create Alert"
    end

    test "shows link to notification channels", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/alerts")

      assert html =~ "Notification Channels"
    end

    test "displays existing alerts", %{conn: conn, user: user} do
      _alert = any_match_alert_fixture(user, name: "My Test Alert")

      {:ok, _lv, html} = live(conn, ~p"/alerts")

      assert html =~ "My Test Alert"
      assert html =~ "Any Match"
    end
  end

  describe "create alert form" do
    test "shows form when Create Alert is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/alerts")

      html = render_click(lv, "show_form")

      assert html =~ "New Alert"
      assert html =~ "Search Query"
      assert html =~ "Alert Type"
      assert html =~ "Cooldown"
    end

    test "hides form when Cancel is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/alerts")

      render_click(lv, "show_form")
      html = render_click(lv, "hide_form")

      refute html =~ "New Alert"
      assert html =~ "Create Alert"
    end

    test "creates alert with valid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/alerts")

      render_click(lv, "show_form")

      html =
        lv
        |> form("#alert-form", %{
          "name" => "Error Alert",
          "search_query" => "level:error",
          "alert_type" => "any_match",
          "cooldown_seconds" => "300"
        })
        |> render_submit()

      assert html =~ "Alert created"
      assert html =~ "Error Alert"
    end

    test "creates velocity alert", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/alerts")

      render_click(lv, "show_form")

      # First change alert type to velocity so velocity fields are shown
      lv
      |> element("#alert-form")
      |> render_change(%{
        "name" => "High Error Rate",
        "search_query" => "level:error",
        "alert_type" => "velocity"
      })

      # Now submit with all fields
      html =
        lv
        |> form("#alert-form", %{
          "name" => "High Error Rate",
          "search_query" => "level:error",
          "alert_type" => "velocity",
          "velocity_threshold" => "50",
          "velocity_window_seconds" => "300",
          "cooldown_seconds" => "900"
        })
        |> render_submit()

      assert html =~ "Alert created"
      assert html =~ "High Error Rate"
      assert html =~ "Velocity"
    end
  end

  describe "edit alert" do
    test "shows form with alert data when Edit is clicked", %{conn: conn, user: user} do
      alert = any_match_alert_fixture(user, name: "Original Name", search_query: "level:warning")

      {:ok, lv, _html} = live(conn, ~p"/alerts")

      html = render_click(lv, "edit_alert", %{"id" => to_string(alert.id)})

      assert html =~ "Edit Alert"
      assert html =~ "Original Name"
      assert html =~ "level:warning"
    end

    test "updates alert", %{conn: conn, user: user} do
      alert = any_match_alert_fixture(user, name: "Old Name")

      {:ok, lv, _html} = live(conn, ~p"/alerts")

      render_click(lv, "edit_alert", %{"id" => to_string(alert.id)})

      html =
        lv
        |> form("#alert-form", %{
          "name" => "New Name"
        })
        |> render_submit()

      assert html =~ "Alert updated"
      assert html =~ "New Name"
    end
  end

  describe "toggle enabled" do
    test "disables enabled alert", %{conn: conn, user: user} do
      alert = any_match_alert_fixture(user, name: "Active Alert", enabled: true)

      {:ok, lv, html} = live(conn, ~p"/alerts")

      # Alert is enabled, should show "Disable" button
      assert html =~ "Disable"

      html = render_click(lv, "toggle_enabled", %{"id" => to_string(alert.id)})

      # Now should show "Enable" and DISABLED badge
      assert html =~ "Enable"
      assert html =~ "DISABLED"
    end

    test "enables disabled alert", %{conn: conn, user: user} do
      alert = any_match_alert_fixture(user, name: "Disabled Alert", enabled: false)

      {:ok, lv, html} = live(conn, ~p"/alerts")

      # Alert is disabled, should show "Enable" button and DISABLED badge
      assert html =~ "Enable"
      assert html =~ "DISABLED"

      html = render_click(lv, "toggle_enabled", %{"id" => to_string(alert.id)})

      # Now should show "Disable" and no DISABLED badge
      assert html =~ "Disable"
    end
  end

  describe "delete alert" do
    test "deletes alert", %{conn: conn, user: user} do
      alert = any_match_alert_fixture(user, name: "To Delete")

      {:ok, lv, html} = live(conn, ~p"/alerts")

      assert html =~ "To Delete"

      html = render_click(lv, "delete_alert", %{"id" => to_string(alert.id)})

      assert html =~ "Alert deleted"
      refute html =~ "To Delete"
    end
  end

  describe "alert history" do
    test "expands history section", %{conn: conn, user: user} do
      alert = any_match_alert_fixture(user, name: "Alert With History")
      _history = alert_history_fixture(alert)

      {:ok, lv, _html} = live(conn, ~p"/alerts")

      html = render_click(lv, "toggle_history", %{"id" => to_string(alert.id)})

      assert html =~ "Recent Triggers"
      assert html =~ "Log Match"
    end

    test "collapses history section on second click", %{conn: conn, user: user} do
      alert = any_match_alert_fixture(user, name: "Alert With History")

      {:ok, lv, _html} = live(conn, ~p"/alerts")

      # Expand
      render_click(lv, "toggle_history", %{"id" => to_string(alert.id)})

      # Collapse
      html = render_click(lv, "toggle_history", %{"id" => to_string(alert.id)})

      refute html =~ "Recent Triggers"
    end

    test "shows empty state when no history", %{conn: conn, user: user} do
      alert = any_match_alert_fixture(user, name: "Alert Without History")

      {:ok, lv, _html} = live(conn, ~p"/alerts")

      html = render_click(lv, "toggle_history", %{"id" => to_string(alert.id)})

      assert html =~ "No triggers yet"
    end
  end
end
