defmodule WhisperLogsWeb.UserLive.Registration do
  use WhisperLogsWeb, :live_view

  alias WhisperLogs.Accounts
  alias WhisperLogs.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm py-12 space-y-6">
        <div class="text-center">
          <.header>
            Register for an account
            <:subtitle>
              Already registered?
              <.link
                navigate={~p"/users/log-in"}
                class="font-semibold text-accent-purple hover:underline"
              >
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <div class="bg-bg-elevated border border-border-default rounded-lg p-6">
          <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
            <.input
              field={@form[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              required
              phx-mounted={JS.focus()}
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="new-password"
              required
            />
            <.input
              field={@form[:password_confirmation]}
              type="password"
              label="Confirm password"
              autocomplete="new-password"
            />

            <.button variant="primary" phx-disable-with="Creating account..." class="w-full">
              Create an account
            </.button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: WhisperLogsWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    if Accounts.registration_allowed?() do
      changeset =
        Accounts.change_user_registration(%User{}, %{},
          validate_unique: false,
          hash_password: false
        )

      {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Registration is closed.")
       |> redirect(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account created successfully!")
         |> redirect(to: ~p"/users/log-in?email=#{user.email}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      Accounts.change_user_registration(%User{}, user_params,
        validate_unique: false,
        hash_password: false
      )

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
