defmodule WhisperLogsWeb.UserLive.RegistrationTest do
  use WhisperLogsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import WhisperLogs.AccountsFixtures

  describe "Registration page" do
    test "renders registration page with password field", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Register"
      assert html =~ "Log in"
      assert html =~ "Password"
      assert html =~ "Confirm password"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces", "password" => "short"})

      assert result =~ "Register"
      assert result =~ "must have the @ sign and no spaces"
      assert result =~ "should be at least 12 character"
    end

    test "redirects to login when registration is closed", %{conn: conn} do
      # Create a user first to close registration
      user_fixture()

      result =
        conn
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert {:ok, _conn} = result
    end
  end

  describe "register user" do
    test "creates account with password and redirects to login", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()

      form =
        form(lv, "#registration_form",
          user: %{
            email: email,
            password: valid_user_password(),
            password_confirmation: valid_user_password()
          }
        )

      {:ok, conn} = follow_redirect(render_submit(form), conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Account created successfully"
    end

    test "redirects when registration is closed due to existing user", %{conn: conn} do
      # Create a user first - this closes registration
      user_fixture(%{email: "test@email.com"})

      # Registration is closed because a user exists
      result =
        conn
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert {:ok, _conn} = result
    end

    test "renders errors for password mismatch", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(
          user: %{
            "email" => unique_user_email(),
            "password" => valid_user_password(),
            "password_confirmation" => "different_password123"
          }
        )

      assert result =~ "does not match password"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Log in"
    end
  end
end
