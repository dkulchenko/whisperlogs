defmodule WhisperLogsWeb.UserLive.Login do
  use WhisperLogsWeb, :live_view

  alias WhisperLogs.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm py-12 space-y-6">
        <div class="text-center">
          <.header>
            <p>Log in</p>
            <:subtitle>
              <%= if @current_scope do %>
                You need to reauthenticate to perform sensitive actions on your account.
              <% else %>
                <%= if @registration_allowed? do %>
                  Don't have an account? <.link
                    navigate={~p"/users/register"}
                    class="font-semibold text-accent-purple hover:underline"
                    phx-no-format
                  >Sign up</.link> for an account now.
                <% end %>
              <% end %>
            </:subtitle>
          </.header>
        </div>

        <div class="bg-bg-elevated border border-border-default rounded-lg p-6">
          <.form
            :let={f}
            for={@form}
            id="login_form"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="email"
              required
              phx-mounted={JS.focus()}
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              required
            />
            <.button variant="primary" class="w-full" name={@form[:remember_me].name} value="true">
              Log in and stay logged in <span aria-hidden="true">→</span>
            </.button>
            <.button class="w-full mt-2">
              Log in only this time
            </.button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     socket
     |> assign(form: form, trigger_submit: false)
     |> assign(registration_allowed?: Accounts.registration_allowed?())}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
