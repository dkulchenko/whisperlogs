defmodule WhisperLogsWeb.SourcesLiveTest do
  use WhisperLogsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WhisperLogs.AccountsFixtures

  alias WhisperLogs.Accounts.User
  alias WhisperLogs.Repo

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
    test "renders sources page with empty state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sources")

      assert html =~ "Sources"
      assert html =~ "No sources yet"
      assert html =~ "HTTP Source"
      assert html =~ "Syslog Source"
    end

    test "displays existing HTTP source", %{conn: conn, user: user} do
      _source = http_source_fixture(user, name: "My HTTP Source", source: "my-app")

      {:ok, _lv, html} = live(conn, ~p"/sources")

      assert html =~ "My HTTP Source"
      assert html =~ "my-app"
      assert html =~ "HTTP"
    end

    test "displays existing syslog source", %{conn: conn, user: user} do
      _source = syslog_source_fixture(user, name: "My Syslog", source: "network")

      {:ok, _lv, html} = live(conn, ~p"/sources")

      assert html =~ "My Syslog"
      assert html =~ "network"
      assert html =~ "SYSLOG"
    end
  end

  describe "HTTP source CRUD" do
    test "creates HTTP source", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sources")

      html =
        lv
        |> form("#http-source-form", %{
          "name" => "Production API",
          "source" => "prod-api"
        })
        |> render_submit()

      # After creation, the key is revealed
      assert html =~ "Production API"
      assert html =~ "prod-api"
      # API key prefix
      assert html =~ "wl_"
    end

    test "shows validation error for invalid source ID", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sources")

      html =
        lv
        |> form("#http-source-form", %{
          "name" => "Test",
          # Contains uppercase and spaces
          "source" => "Invalid Source ID"
        })
        |> render_submit()

      assert html =~ "lowercase letters"
    end

    test "edits HTTP source name", %{conn: conn, user: user} do
      source = http_source_fixture(user, name: "Old Name", source: "my-app")

      {:ok, lv, _html} = live(conn, ~p"/sources")

      # Click edit
      render_click(lv, "edit_source", %{"id" => source.id})

      # Submit update
      html =
        lv
        |> form("#http-source-form", %{
          "name" => "New Name"
        })
        |> render_submit()

      assert html =~ "Source updated successfully"
      assert html =~ "New Name"
    end

    test "cancels edit", %{conn: conn, user: user} do
      source = http_source_fixture(user, name: "Original Name", source: "test-app")

      {:ok, lv, _html} = live(conn, ~p"/sources")

      # Click edit
      render_click(lv, "edit_source", %{"id" => source.id})

      # Cancel
      html = render_click(lv, "cancel_edit")

      # Form should be reset (no "Save Changes" button)
      assert html =~ "Create HTTP Source"
    end
  end

  describe "Syslog source CRUD" do
    test "creates syslog source", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sources")

      html =
        lv
        |> form("#syslog-source-form", %{
          "name" => "Router Logs",
          "source" => "router",
          "port" => "5514",
          "transport" => "udp",
          "auto_register_hosts" => "true"
        })
        |> render_submit()

      assert html =~ "Syslog source created"
      assert html =~ "Router Logs"
      assert html =~ ":5514"
    end

    test "edits syslog source", %{conn: conn, user: user} do
      source = syslog_source_fixture(user, name: "Old Syslog", source: "syslog-test")

      {:ok, lv, _html} = live(conn, ~p"/sources")

      # Click edit
      render_click(lv, "edit_source", %{"id" => source.id})

      # Submit update
      html =
        lv
        |> form("#syslog-source-form", %{
          "name" => "Updated Syslog"
        })
        |> render_submit()

      assert html =~ "Source updated successfully"
      assert html =~ "Updated Syslog"
    end
  end

  describe "reveal API key" do
    test "reveals and hides API key", %{conn: conn, user: user} do
      source = http_source_fixture(user, name: "Test API", source: "test-api")

      {:ok, lv, html} = live(conn, ~p"/sources")

      # Initially key is hidden
      refute html =~ source.key
      assert html =~ "Reveal Key"

      # Reveal
      html = render_click(lv, "toggle_reveal", %{"id" => source.id})
      assert html =~ source.key
      assert html =~ "Hide"

      # Hide again
      html = render_click(lv, "toggle_reveal", %{"id" => source.id})
      refute html =~ source.key
      assert html =~ "Reveal Key"
    end
  end

  describe "revoke source" do
    test "revokes HTTP source", %{conn: conn, user: user} do
      source = http_source_fixture(user, name: "To Revoke", source: "revoke-me")

      {:ok, lv, html} = live(conn, ~p"/sources")

      assert html =~ "To Revoke"

      html = render_click(lv, "revoke", %{"id" => source.id})

      assert html =~ "Source revoked successfully"
      refute html =~ "To Revoke"
    end

    test "revokes syslog source", %{conn: conn, user: user} do
      source = syslog_source_fixture(user, name: "Syslog to Revoke", source: "revoke-syslog")

      {:ok, lv, html} = live(conn, ~p"/sources")

      assert html =~ "Syslog to Revoke"

      html = render_click(lv, "revoke", %{"id" => source.id})

      assert html =~ "Source revoked successfully"
      refute html =~ "Syslog to Revoke"
    end
  end
end
