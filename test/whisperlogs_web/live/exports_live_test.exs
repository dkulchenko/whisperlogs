defmodule WhisperLogsWeb.ExportsLiveTest do
  use WhisperLogsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WhisperLogs.ExportsFixtures

  alias WhisperLogs.Accounts.User
  alias WhisperLogs.Repo

  setup do
    user = ensure_local_user()
    scope = WhisperLogs.Accounts.Scope.for_user(user)
    {:ok, user: user, scope: scope}
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
    test "renders exports page with empty state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/exports")

      assert html =~ "Exports"
      assert html =~ "No destinations configured"
      assert html =~ "Add Destination"
    end

    test "displays existing destinations", %{conn: conn, scope: scope} do
      _dest = local_destination_fixture(scope, name: "My Backups")

      {:ok, _lv, html} = live(conn, ~p"/exports")

      assert html =~ "My Backups"
      assert html =~ "LOCAL"
    end

    test "displays export history", %{conn: conn, scope: scope} do
      dest = local_destination_fixture(scope)
      _job = completed_export_job_fixture(dest, scope)

      {:ok, _lv, html} = live(conn, ~p"/exports")

      assert html =~ "COMPLETED"
    end
  end

  describe "destination form" do
    test "shows form when Add Destination is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/exports")

      html = render_click(lv, "show_destination_form")

      assert html =~ "New Destination"
      assert html =~ "Destination Type"
      assert html =~ "Local Folder"
    end

    test "creates local destination", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/exports")

      render_click(lv, "show_destination_form")

      html =
        lv
        |> form("#destination-form", %{
          "name" => "Test Local",
          "destination_type" => "local",
          "local_path" => "/tmp/exports"
        })
        |> render_submit()

      assert html =~ "Destination created"
      assert html =~ "Test Local"
    end

    test "hides form when Cancel is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/exports")

      render_click(lv, "show_destination_form")
      html = render_click(lv, "hide_destination_form")

      refute html =~ "New Destination"
      assert html =~ "Add Destination"
    end
  end

  describe "destination actions" do
    test "toggles destination enabled/disabled", %{conn: conn, scope: scope} do
      dest = local_destination_fixture(scope, name: "Toggle Test", enabled: true)

      {:ok, lv, html} = live(conn, ~p"/exports")
      assert html =~ "Disable"

      html = render_click(lv, "toggle_enabled", %{"id" => to_string(dest.id)})
      assert html =~ "DISABLED"
      assert html =~ "Enable"
    end

    test "deletes destination", %{conn: conn, scope: scope} do
      dest = local_destination_fixture(scope, name: "To Delete")

      {:ok, lv, html} = live(conn, ~p"/exports")
      assert html =~ "To Delete"

      html = render_click(lv, "delete_destination", %{"id" => to_string(dest.id)})
      assert html =~ "Destination deleted"
      refute html =~ "To Delete"
    end
  end

  describe "export modal" do
    test "shows export modal", %{conn: conn, scope: scope} do
      dest = local_destination_fixture(scope, name: "Export Target")

      {:ok, lv, _html} = live(conn, ~p"/exports")

      html = render_click(lv, "show_export_modal", %{"id" => to_string(dest.id)})

      assert html =~ "Manual Export"
      assert html =~ "Export Target"
      assert html =~ "From Date"
      assert html =~ "To Date"
    end

    test "hides export modal", %{conn: conn, scope: scope} do
      dest = local_destination_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/exports")

      render_click(lv, "show_export_modal", %{"id" => to_string(dest.id)})
      html = render_click(lv, "hide_export_modal")

      refute html =~ "Manual Export"
    end
  end
end
