defmodule WhisperLogsWeb.NotificationChannelsLive do
  use WhisperLogsWeb, :live_view

  alias WhisperLogs.Alerts

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    channels = Alerts.list_notification_channels(user)

    {:ok,
     socket
     |> assign(:page_title, "Notification Channels")
     |> assign(:channels, channels)
     |> assign(:show_email_form, false)
     |> assign(:show_pushover_form, false)
     |> assign(:editing_channel, nil)
     |> assign(:email_form, to_form(%{"name" => "", "email" => ""}))
     |> assign(
       :pushover_form,
       to_form(%{"name" => "", "user_key" => "", "app_token" => "", "priority" => "0"})
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex-1 overflow-y-auto">
        <div class="max-w-4xl mx-auto px-6 py-8">
        <.header>
          Notification Channels
          <:subtitle>
            Configure where alert notifications are sent. Create email or Pushover channels,
            then attach them to alerts.
          </:subtitle>
        </.header>

        <div class="mt-8 flex gap-3">
          <button
            type="button"
            phx-click="toggle_email_form"
            class={[
              "flex items-center gap-2 px-4 py-2 rounded-lg font-medium text-sm transition-colors",
              "bg-accent-purple/10 text-accent-purple hover:bg-accent-purple/20",
              "border border-accent-purple/30"
            ]}
          >
            <.icon name="hero-envelope" class="size-4" /> Add Email Channel
          </button>
          <button
            type="button"
            phx-click="toggle_pushover_form"
            class={[
              "flex items-center gap-2 px-4 py-2 rounded-lg font-medium text-sm transition-colors",
              "bg-accent-purple/10 text-accent-purple hover:bg-accent-purple/20",
              "border border-accent-purple/30"
            ]}
          >
            <.icon name="hero-device-phone-mobile" class="size-4" /> Add Pushover Channel
          </button>
        </div>

        <%!-- Email Form --%>
        <div
          :if={@show_email_form}
          class="mt-6 bg-bg-elevated border border-border-default rounded-lg p-6"
        >
          <div class="flex items-center gap-2 mb-4">
            <.icon name="hero-envelope" class="size-5 text-accent-purple" />
            <h3 class="text-lg font-semibold text-text-primary">
              {if @editing_channel && @editing_channel.channel_type == "email",
                do: "Edit Email Channel",
                else: "New Email Channel"}
            </h3>
          </div>
          <.form for={@email_form} id="email-channel-form" phx-submit="save_email" class="space-y-4">
            <.input
              field={@email_form[:name]}
              type="text"
              label="Name"
              placeholder="e.g., Work Email"
            />
            <.input
              field={@email_form[:email]}
              type="email"
              label="Email Address"
              placeholder="you@example.com"
            />
            <div class="flex gap-3">
              <.button
                variant="primary"
                phx-disable-with={if @editing_channel, do: "Saving...", else: "Creating..."}
              >
                {if @editing_channel, do: "Save Changes", else: "Create Channel"}
              </.button>
              <button
                type="button"
                phx-click="toggle_email_form"
                class="px-4 py-2 text-sm font-medium text-text-secondary hover:text-text-primary rounded-lg transition-colors"
              >
                Cancel
              </button>
            </div>
          </.form>
        </div>

        <%!-- Pushover Form --%>
        <div
          :if={@show_pushover_form}
          class="mt-6 bg-bg-elevated border border-border-default rounded-lg p-6"
        >
          <div class="flex items-center gap-2 mb-4">
            <.icon name="hero-device-phone-mobile" class="size-5 text-accent-purple" />
            <h3 class="text-lg font-semibold text-text-primary">
              {if @editing_channel && @editing_channel.channel_type == "pushover",
                do: "Edit Pushover Channel",
                else: "New Pushover Channel"}
            </h3>
          </div>
          <.form
            for={@pushover_form}
            id="pushover-channel-form"
            phx-submit="save_pushover"
            class="space-y-4"
          >
            <.input
              field={@pushover_form[:name]}
              type="text"
              label="Name"
              placeholder="e.g., Mobile Alerts"
            />
            <.input
              field={@pushover_form[:user_key]}
              type="text"
              label="User Key"
              placeholder="Your Pushover user key"
            />
            <.input
              field={@pushover_form[:app_token]}
              type="text"
              label="Application Token"
              placeholder="Your Pushover application token"
            />
            <.input
              field={@pushover_form[:priority]}
              type="select"
              label="Default Priority"
              options={[
                {"Lowest (-2)", "-2"},
                {"Low (-1)", "-1"},
                {"Normal (0)", "0"},
                {"High (1)", "1"},
                {"Emergency (2)", "2"}
              ]}
            />
            <p class="text-sm text-text-tertiary">
              Get your keys from
              <a
                href="https://pushover.net"
                target="_blank"
                class="text-accent-purple hover:underline"
              >
                pushover.net
              </a>
            </p>
            <div class="flex gap-3">
              <.button
                variant="primary"
                phx-disable-with={if @editing_channel, do: "Saving...", else: "Creating..."}
              >
                {if @editing_channel, do: "Save Changes", else: "Create Channel"}
              </.button>
              <button
                type="button"
                phx-click="toggle_pushover_form"
                class="px-4 py-2 text-sm font-medium text-text-secondary hover:text-text-primary rounded-lg transition-colors"
              >
                Cancel
              </button>
            </div>
          </.form>
        </div>

        <div class="mt-10">
          <h3 class="text-lg font-semibold text-text-primary mb-4">Your Channels</h3>

          <div class="space-y-3">
            <%= if @channels == [] do %>
              <div class="flex flex-col items-center justify-center py-12 text-text-tertiary">
                <.icon name="hero-bell-slash" class="size-10 mb-3 opacity-50" />
                <p class="text-text-secondary font-medium">No notification channels yet</p>
                <p class="mt-1 text-sm">Create one above to start receiving alerts.</p>
              </div>
            <% end %>

            <div
              :for={channel <- @channels}
              id={"channel-row-#{channel.id}"}
              class="bg-bg-elevated border border-border-default rounded-lg p-4 hover:border-border-subtle transition-colors"
            >
              <div class="flex items-center justify-between">
                <div class="flex-1">
                  <div class="flex items-center gap-3">
                    <%= if channel.channel_type == "email" do %>
                      <.icon name="hero-envelope" class="size-4 text-text-tertiary" />
                    <% else %>
                      <.icon name="hero-device-phone-mobile" class="size-4 text-text-tertiary" />
                    <% end %>
                    <span class="font-medium text-text-primary">{channel.name}</span>
                    <span class={[
                      "px-2 py-0.5 rounded text-xs font-medium",
                      channel.channel_type == "email" && "bg-blue-500/10 text-blue-400",
                      channel.channel_type == "pushover" && "bg-green-500/10 text-green-400"
                    ]}>
                      {String.upcase(channel.channel_type)}
                    </span>
                    <span
                      :if={!channel.enabled}
                      class="px-2 py-0.5 rounded text-xs font-medium bg-red-500/10 text-red-400"
                    >
                      DISABLED
                    </span>
                  </div>
                  <div class="mt-1.5 text-sm text-text-tertiary">
                    <%= if channel.channel_type == "email" do %>
                      {channel.config["email"]}
                    <% else %>
                      Priority: {format_priority(channel.config["priority"])}
                    <% end %>
                  </div>
                </div>
                <div class="flex items-center gap-2">
                  <button
                    type="button"
                    phx-click="edit_channel"
                    phx-value-id={channel.id}
                    class="px-3 py-1.5 text-sm font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface rounded-lg transition-colors"
                  >
                    Edit
                  </button>
                  <button
                    type="button"
                    phx-click="toggle_enabled"
                    phx-value-id={channel.id}
                    class={[
                      "px-3 py-1.5 text-sm font-medium rounded-lg transition-colors",
                      channel.enabled && "text-amber-400 hover:text-amber-300 hover:bg-amber-500/10",
                      !channel.enabled && "text-green-400 hover:text-green-300 hover:bg-green-500/10"
                    ]}
                  >
                    {if channel.enabled, do: "Disable", else: "Enable"}
                  </button>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={channel.id}
                    data-confirm="Are you sure you want to delete this channel? Alerts using this channel will no longer send to it."
                    class="px-3 py-1.5 text-sm font-medium text-red-400 hover:text-red-300 hover:bg-red-500/10 rounded-lg transition-colors"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("toggle_email_form", _, socket) do
    {:noreply,
     socket
     |> assign(:show_email_form, !socket.assigns.show_email_form)
     |> assign(:show_pushover_form, false)
     |> assign(:editing_channel, nil)
     |> assign(:email_form, to_form(%{"name" => "", "email" => ""}))}
  end

  def handle_event("toggle_pushover_form", _, socket) do
    {:noreply,
     socket
     |> assign(:show_pushover_form, !socket.assigns.show_pushover_form)
     |> assign(:show_email_form, false)
     |> assign(:editing_channel, nil)
     |> assign(
       :pushover_form,
       to_form(%{"name" => "", "user_key" => "", "app_token" => "", "priority" => "0"})
     )}
  end

  def handle_event("edit_channel", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Alerts.get_notification_channel(user, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Channel not found")}

      %{channel_type: "email"} = channel ->
        form_data = %{
          "name" => channel.name,
          "email" => channel.config["email"]
        }

        {:noreply,
         socket
         |> assign(:editing_channel, channel)
         |> assign(:show_email_form, true)
         |> assign(:show_pushover_form, false)
         |> assign(:email_form, to_form(form_data))}

      %{channel_type: "pushover"} = channel ->
        form_data = %{
          "name" => channel.name,
          "user_key" => channel.config["user_key"],
          "app_token" => channel.config["app_token"],
          "priority" => to_string(channel.config["priority"] || 0)
        }

        {:noreply,
         socket
         |> assign(:editing_channel, channel)
         |> assign(:show_pushover_form, true)
         |> assign(:show_email_form, false)
         |> assign(:pushover_form, to_form(form_data))}
    end
  end

  def handle_event("save_email", %{"name" => name, "email" => email}, socket) do
    user = socket.assigns.current_scope.user

    if socket.assigns.editing_channel do
      # Update mode
      attrs = %{
        name: name,
        config: %{"email" => email}
      }

      case Alerts.update_notification_channel(socket.assigns.editing_channel, attrs) do
        {:ok, updated} ->
          channels =
            Enum.map(socket.assigns.channels, fn c ->
              if c.id == updated.id, do: updated, else: c
            end)

          {:noreply,
           socket
           |> assign(:channels, channels)
           |> assign(:show_email_form, false)
           |> assign(:editing_channel, nil)
           |> assign(:email_form, to_form(%{"name" => "", "email" => ""}))
           |> put_flash(:info, "Email channel updated")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, format_errors(changeset))}
      end
    else
      # Create mode
      attrs = %{
        channel_type: "email",
        name: name,
        config: %{"email" => email}
      }

      case Alerts.create_notification_channel(user, attrs) do
        {:ok, channel} ->
          {:noreply,
           socket
           |> assign(:channels, [channel | socket.assigns.channels])
           |> assign(:show_email_form, false)
           |> assign(:email_form, to_form(%{"name" => "", "email" => ""}))
           |> put_flash(:info, "Email channel created")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, format_errors(changeset))}
      end
    end
  end

  def handle_event("save_pushover", params, socket) do
    user = socket.assigns.current_scope.user
    priority = String.to_integer(params["priority"])

    if socket.assigns.editing_channel do
      # Update mode
      attrs = %{
        name: params["name"],
        config: %{
          "user_key" => params["user_key"],
          "app_token" => params["app_token"],
          "priority" => priority
        }
      }

      case Alerts.update_notification_channel(socket.assigns.editing_channel, attrs) do
        {:ok, updated} ->
          channels =
            Enum.map(socket.assigns.channels, fn c ->
              if c.id == updated.id, do: updated, else: c
            end)

          {:noreply,
           socket
           |> assign(:channels, channels)
           |> assign(:show_pushover_form, false)
           |> assign(:editing_channel, nil)
           |> assign(
             :pushover_form,
             to_form(%{"name" => "", "user_key" => "", "app_token" => "", "priority" => "0"})
           )
           |> put_flash(:info, "Pushover channel updated")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, format_errors(changeset))}
      end
    else
      # Create mode
      attrs = %{
        channel_type: "pushover",
        name: params["name"],
        config: %{
          "user_key" => params["user_key"],
          "app_token" => params["app_token"],
          "priority" => priority
        }
      }

      case Alerts.create_notification_channel(user, attrs) do
        {:ok, channel} ->
          {:noreply,
           socket
           |> assign(:channels, [channel | socket.assigns.channels])
           |> assign(:show_pushover_form, false)
           |> assign(
             :pushover_form,
             to_form(%{"name" => "", "user_key" => "", "app_token" => "", "priority" => "0"})
           )
           |> put_flash(:info, "Pushover channel created")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, format_errors(changeset))}
      end
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Alerts.get_notification_channel(user, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Channel not found")}

      channel ->
        case Alerts.update_notification_channel(channel, %{enabled: !channel.enabled}) do
          {:ok, updated} ->
            channels =
              Enum.map(socket.assigns.channels, fn c ->
                if c.id == updated.id, do: updated, else: c
              end)

            {:noreply, assign(socket, :channels, channels)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update channel")}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Alerts.get_notification_channel(user, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Channel not found")}

      channel ->
        case Alerts.delete_notification_channel(channel) do
          {:ok, _} ->
            channels = Enum.reject(socket.assigns.channels, &(&1.id == channel.id))

            {:noreply,
             socket
             |> assign(:channels, channels)
             |> put_flash(:info, "Channel deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete channel")}
        end
    end
  end

  defp format_priority(-2), do: "Lowest"
  defp format_priority(-1), do: "Low"
  defp format_priority(0), do: "Normal"
  defp format_priority(1), do: "High"
  defp format_priority(2), do: "Emergency"
  defp format_priority(nil), do: "Normal"
  defp format_priority(p), do: to_string(p)

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
    |> Enum.join("; ")
  end
end
