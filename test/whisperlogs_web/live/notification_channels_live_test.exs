defmodule WhisperLogsWeb.NotificationChannelsLiveTest do
  use WhisperLogsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WhisperLogs.AlertsFixtures

  alias WhisperLogs.Accounts.User
  alias WhisperLogs.Repo

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
    test "renders notification channels page with empty state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/notification-channels")

      assert html =~ "Notification Channels"
      assert html =~ "No notification channels yet"
    end

    test "displays existing email channel", %{conn: conn, user: user} do
      _channel = email_channel_fixture(user, name: "My Email Channel")

      {:ok, _lv, html} = live(conn, ~p"/notification-channels")

      assert html =~ "My Email Channel"
      assert html =~ "EMAIL"
    end

    test "displays existing pushover channel", %{conn: conn, user: user} do
      _channel = pushover_channel_fixture(user, name: "My Pushover")

      {:ok, _lv, html} = live(conn, ~p"/notification-channels")

      assert html =~ "My Pushover"
      assert html =~ "PUSHOVER"
    end
  end

  describe "create channel" do
    test "shows email form when Add Email is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/notification-channels")

      html = render_click(lv, "toggle_email_form")

      assert html =~ "New Email Channel"
      assert html =~ "Email Address"
    end

    test "creates email channel", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/notification-channels")

      render_click(lv, "toggle_email_form")

      html =
        lv
        |> form("#email-channel-form", %{
          "name" => "Test Email",
          "email" => "test@example.com"
        })
        |> render_submit()

      # Channel should appear in the list
      assert html =~ "Test Email"
      assert html =~ "test@example.com"
    end

    test "shows pushover form when Add Pushover is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/notification-channels")

      html = render_click(lv, "toggle_pushover_form")

      assert html =~ "New Pushover Channel"
      assert html =~ "User Key"
    end

    test "creates pushover channel", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/notification-channels")

      render_click(lv, "toggle_pushover_form")

      html =
        lv
        |> form("#pushover-channel-form", %{
          "name" => "Test Pushover",
          "user_key" => "user123",
          "app_token" => "app456"
        })
        |> render_submit()

      # Channel should appear in the list
      assert html =~ "Test Pushover"
      assert html =~ "PUSHOVER"
    end
  end

  describe "channel actions" do
    test "edits email channel", %{conn: conn, user: user} do
      channel = email_channel_fixture(user, name: "Old Name")

      {:ok, lv, _html} = live(conn, ~p"/notification-channels")

      render_click(lv, "edit_channel", %{"id" => to_string(channel.id)})

      html =
        lv
        |> form("#email-channel-form", %{
          "name" => "New Name"
        })
        |> render_submit()

      # Channel name should be updated
      assert html =~ "New Name"
    end

    test "deletes channel", %{conn: conn, user: user} do
      channel = email_channel_fixture(user, name: "To Delete")

      {:ok, lv, html} = live(conn, ~p"/notification-channels")
      assert html =~ "To Delete"

      html = render_click(lv, "delete", %{"id" => to_string(channel.id)})
      refute html =~ "To Delete"
    end

    test "toggles channel enabled/disabled", %{conn: conn, user: user} do
      channel = email_channel_fixture(user, name: "Toggle Channel", enabled: true)

      {:ok, lv, html} = live(conn, ~p"/notification-channels")
      assert html =~ "Disable"

      html = render_click(lv, "toggle_enabled", %{"id" => to_string(channel.id)})
      assert html =~ "Enable"
      assert html =~ "DISABLED"
    end
  end
end
