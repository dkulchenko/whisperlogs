defmodule WhisperLogsWeb.AlertsLive do
  use WhisperLogsWeb, :live_view

  alias WhisperLogs.Alerts
  alias WhisperLogs.Logs

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    alerts = Alerts.list_alerts(user)
    channels = Alerts.list_notification_channels(user)

    {:ok,
     socket
     |> assign(:page_title, "Alerts")
     |> assign(:alerts, alerts)
     |> assign(:channels, channels)
     |> assign(:show_form, false)
     |> assign(:editing_alert, nil)
     |> assign(:expanded_history, nil)
     |> assign(:history_entries, [])
     |> assign(:match_counts, nil)
     |> assign(:counting, false)
     |> reset_form()}
  end

  defp reset_form(socket) do
    socket
    |> assign(
      :form,
      to_form(%{
        "name" => "",
        "description" => "",
        "search_query" => "",
        "alert_type" => "any_match",
        "velocity_threshold" => "10",
        "velocity_window_seconds" => "300",
        "cooldown_seconds" => "300",
        "channel_ids" => []
      })
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-4xl mx-auto px-6 py-8">
        <.header>
          Alerts
          <:subtitle>
            Create alerts to get notified when log patterns match or velocity thresholds are exceeded.
          </:subtitle>
        </.header>

        <div class="mt-8 flex items-center gap-3">
          <button
            :if={!@show_form}
            type="button"
            phx-click="show_form"
            class={[
              "flex items-center gap-2 px-4 py-2 rounded-lg font-medium text-sm transition-colors",
              "bg-accent-purple/10 text-accent-purple hover:bg-accent-purple/20",
              "border border-accent-purple/30"
            ]}
          >
            <.icon name="hero-plus" class="size-4" /> Create Alert
          </button>
          <.link
            :if={!@show_form}
            navigate={~p"/notification-channels"}
            class="flex items-center gap-2 px-4 py-2 rounded-lg font-medium text-sm text-text-secondary hover:text-text-primary hover:bg-bg-surface border border-border-default transition-colors"
          >
            <.icon name="hero-bell" class="size-4" /> Notification Channels
          </.link>
        </div>

        <%!-- Alert Form --%>
        <div :if={@show_form} class="mt-6 bg-bg-elevated border border-border-default rounded-lg p-6">
          <div class="flex items-center gap-2 mb-4">
            <.icon name="hero-bell-alert" class="size-5 text-accent-purple" />
            <h3 class="text-lg font-semibold text-text-primary">
              {if @editing_alert, do: "Edit Alert", else: "New Alert"}
            </h3>
          </div>

          <.form
            for={@form}
            id="alert-form"
            phx-submit="save_alert"
            phx-change="validate_form"
            class="space-y-4"
          >
            <.input
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="e.g., Error Rate Alert"
              phx-debounce="300"
            />

            <.input
              field={@form[:description]}
              type="text"
              label="Description (optional)"
              placeholder="What does this alert monitor?"
              phx-debounce="300"
            />

            <div>
              <label class="block text-sm font-medium text-text-primary mb-2">Search Query</label>
              <.input
                field={@form[:search_query]}
                type="text"
                placeholder="e.g., level:error source:prod"
                phx-debounce="300"
              />
              <%!-- Match counts preview --%>
              <div class="mt-2 flex items-center gap-4 text-sm">
                <%= if @counting do %>
                  <span class="text-text-tertiary flex items-center gap-1.5">
                    <span class="inline-block w-3 h-3 border-2 border-accent-purple/50 border-t-accent-purple rounded-full animate-spin">
                    </span>
                    Counting matches...
                  </span>
                <% else %>
                  <%= if @match_counts do %>
                    <span class="text-text-tertiary">Matches:</span>
                    <span class={[
                      "px-2 py-0.5 rounded text-xs font-medium",
                      @match_counts.hour > 0 && "bg-emerald-500/20 text-emerald-400",
                      @match_counts.hour == 0 && "bg-bg-surface text-text-tertiary"
                    ]}>
                      {format_count(@match_counts.hour)} in 1h
                    </span>
                    <span class={[
                      "px-2 py-0.5 rounded text-xs font-medium",
                      @match_counts.day > 0 && "bg-emerald-500/20 text-emerald-400",
                      @match_counts.day == 0 && "bg-bg-surface text-text-tertiary"
                    ]}>
                      {format_count(@match_counts.day)} in 24h
                    </span>
                    <span class={[
                      "px-2 py-0.5 rounded text-xs font-medium",
                      @match_counts.week > 0 && "bg-emerald-500/20 text-emerald-400",
                      @match_counts.week == 0 && "bg-bg-surface text-text-tertiary"
                    ]}>
                      {format_count(@match_counts.week)} in 7d
                    </span>
                  <% end %>
                <% end %>
              </div>
              <p class="mt-1 text-sm text-text-tertiary">
                Same syntax as the logs search. Examples: <code class="text-accent-purple">level:error</code>, <code class="text-accent-purple">user_id:123</code>,
                <code class="text-accent-purple">duration_ms:>1000</code>
              </p>
            </div>

            <.input
              field={@form[:alert_type]}
              type="select"
              label="Alert Type"
              options={[
                {"Any Match - Alert when any log matches", "any_match"},
                {"Velocity - Alert when match count exceeds threshold", "velocity"}
              ]}
            />

            <div :if={@form[:alert_type].value == "velocity"} class="grid grid-cols-2 gap-4">
              <.input
                field={@form[:velocity_threshold]}
                type="number"
                label="Threshold (matches)"
                min="1"
                phx-debounce="300"
              />
              <.input
                field={@form[:velocity_window_seconds]}
                type="select"
                label="Time Window"
                options={[
                  {"1 minute", "60"},
                  {"5 minutes", "300"},
                  {"15 minutes", "900"},
                  {"1 hour", "3600"}
                ]}
              />
            </div>

            <.input
              field={@form[:cooldown_seconds]}
              type="select"
              label="Cooldown (prevent repeat alerts)"
              options={[
                {"1 minute", "60"},
                {"5 minutes", "300"},
                {"15 minutes", "900"},
                {"30 minutes", "1800"},
                {"1 hour", "3600"},
                {"4 hours", "14400"},
                {"24 hours", "86400"}
              ]}
            />

            <div>
              <label class="block text-sm font-medium text-text-primary mb-2">
                Notification Channels
              </label>
              <%= if @channels == [] do %>
                <p class="text-sm text-text-tertiary">
                  No channels configured.
                  <.link
                    navigate={~p"/notification-channels"}
                    class="text-accent-purple hover:underline"
                  >
                    Create one first
                  </.link>
                </p>
              <% else %>
                <div class="space-y-2">
                  <label
                    :for={channel <- @channels}
                    class="flex items-center gap-3 p-3 bg-bg-surface border border-border-default rounded-lg cursor-pointer hover:border-border-subtle transition-colors"
                  >
                    <input
                      type="checkbox"
                      name="channel_ids[]"
                      value={channel.id}
                      checked={to_string(channel.id) in (@form[:channel_ids].value || [])}
                      class="rounded border-border-default text-accent-purple focus:ring-accent-purple"
                    />
                    <div class="flex items-center gap-2">
                      <%= if channel.channel_type == "email" do %>
                        <.icon name="hero-envelope" class="size-4 text-text-tertiary" />
                      <% else %>
                        <.icon name="hero-device-phone-mobile" class="size-4 text-text-tertiary" />
                      <% end %>
                      <span class="text-text-primary">{channel.name}</span>
                      <span class="text-xs text-text-tertiary">
                        ({channel.channel_type})
                      </span>
                    </div>
                  </label>
                </div>
              <% end %>
            </div>

            <div class="flex gap-3 pt-2">
              <.button variant="primary" phx-disable-with="Saving...">
                {if @editing_alert, do: "Update Alert", else: "Create Alert"}
              </.button>
              <button
                type="button"
                phx-click="hide_form"
                class="px-4 py-2 text-sm font-medium text-text-secondary hover:text-text-primary rounded-lg transition-colors"
              >
                Cancel
              </button>
            </div>
          </.form>
        </div>

        <div class="mt-10">
          <h3 class="text-lg font-semibold text-text-primary mb-4">Your Alerts</h3>

          <div class="space-y-3">
            <%= if @alerts == [] do %>
              <div class="flex flex-col items-center justify-center py-12 text-text-tertiary">
                <.icon name="hero-bell-slash" class="size-10 mb-3 opacity-50" />
                <p class="text-text-secondary font-medium">No alerts yet</p>
                <p class="mt-1 text-sm">Create one above to start monitoring.</p>
              </div>
            <% end %>

            <div
              :for={alert <- @alerts}
              id={"alert-row-#{alert.id}"}
              class="bg-bg-elevated border border-border-default rounded-lg overflow-hidden"
            >
              <div class="p-4 hover:bg-bg-surface/50 transition-colors">
                <div class="flex items-center justify-between">
                  <div class="flex-1">
                    <div class="flex items-center gap-3">
                      <span class="font-medium text-text-primary">{alert.name}</span>
                      <span class={[
                        "px-2 py-0.5 rounded text-xs font-medium",
                        alert.alert_type == "any_match" && "bg-blue-500/10 text-blue-400",
                        alert.alert_type == "velocity" && "bg-amber-500/10 text-amber-400"
                      ]}>
                        {format_alert_type(alert.alert_type)}
                      </span>
                      <span
                        :if={!alert.enabled}
                        class="px-2 py-0.5 rounded text-xs font-medium bg-red-500/10 text-red-400"
                      >
                        DISABLED
                      </span>
                    </div>
                    <div class="mt-1.5 text-sm text-text-tertiary font-mono">
                      {alert.search_query}
                    </div>
                    <div class="mt-1 flex items-center gap-4 text-sm text-text-tertiary">
                      <%= if alert.alert_type == "velocity" do %>
                        <span>
                          ≥ {alert.velocity_threshold} in {format_window(
                            alert.velocity_window_seconds
                          )}
                        </span>
                      <% end %>
                      <span>Cooldown: {format_window(alert.cooldown_seconds)}</span>
                      <span :if={alert.last_triggered_at}>
                        Last triggered: {format_relative_time(alert.last_triggered_at)}
                      </span>
                      <span class="flex items-center gap-1">
                        <.icon name="hero-bell" class="size-3" />
                        {length(alert.notification_channels)} channel(s)
                      </span>
                    </div>
                  </div>
                  <div class="flex items-center gap-2">
                    <button
                      type="button"
                      phx-click="toggle_history"
                      phx-value-id={alert.id}
                      class="px-3 py-1.5 text-sm font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface rounded-lg transition-colors"
                    >
                      History
                    </button>
                    <button
                      type="button"
                      phx-click="edit_alert"
                      phx-value-id={alert.id}
                      class="px-3 py-1.5 text-sm font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface rounded-lg transition-colors"
                    >
                      Edit
                    </button>
                    <button
                      type="button"
                      phx-click="toggle_enabled"
                      phx-value-id={alert.id}
                      class={[
                        "px-3 py-1.5 text-sm font-medium rounded-lg transition-colors",
                        alert.enabled && "text-amber-400 hover:text-amber-300 hover:bg-amber-500/10",
                        !alert.enabled && "text-green-400 hover:text-green-300 hover:bg-green-500/10"
                      ]}
                    >
                      {if alert.enabled, do: "Disable", else: "Enable"}
                    </button>
                    <button
                      type="button"
                      phx-click="delete_alert"
                      phx-value-id={alert.id}
                      data-confirm="Are you sure you want to delete this alert?"
                      class="px-3 py-1.5 text-sm font-medium text-red-400 hover:text-red-300 hover:bg-red-500/10 rounded-lg transition-colors"
                    >
                      Delete
                    </button>
                  </div>
                </div>
              </div>

              <%!-- History Section --%>
              <div
                :if={@expanded_history == alert.id}
                class="border-t border-border-default bg-bg-surface/50 p-4"
              >
                <h4 class="text-sm font-medium text-text-primary mb-3">Recent Triggers</h4>
                <%= if @history_entries == [] do %>
                  <p class="text-sm text-text-tertiary">No triggers yet.</p>
                <% else %>
                  <div class="space-y-2 max-h-64 overflow-y-auto">
                    <div
                      :for={entry <- @history_entries}
                      class="flex items-start gap-3 p-2 bg-bg-base rounded border border-border-default"
                    >
                      <div class="flex-1 min-w-0">
                        <div class="flex items-center gap-2 text-sm">
                          <span class="text-text-primary font-medium">
                            {format_trigger_type(entry.trigger_type)}
                          </span>
                          <span class="text-text-tertiary">
                            {Calendar.strftime(entry.triggered_at, "%b %d, %Y %H:%M:%S")}
                          </span>
                        </div>
                        <div class="mt-1 text-xs text-text-tertiary font-mono truncate">
                          {format_trigger_data(entry.trigger_type, entry.trigger_data)}
                        </div>
                        <div :if={entry.notifications_sent != []} class="mt-1 flex gap-2">
                          <span
                            :for={notif <- entry.notifications_sent}
                            class={[
                              "px-1.5 py-0.5 rounded text-xs",
                              notif["success"] && "bg-green-500/10 text-green-400",
                              !notif["success"] && "bg-red-500/10 text-red-400"
                            ]}
                          >
                            {notif["channel_name"]}
                          </span>
                        </div>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("show_form", _, socket) do
    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_alert, nil)
     |> reset_form()}
  end

  def handle_event("hide_form", _, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:editing_alert, nil)
     |> assign(:match_counts, nil)
     |> assign(:counting, false)
     |> reset_form()}
  end

  def handle_event("validate_form", params, socket) do
    form_params = Map.drop(params, ["_target"])
    target = params["_target"]

    socket = assign(socket, :form, to_form(form_params))

    # Trigger async counting when search_query changes
    socket =
      if target == ["search_query"] do
        search_query = form_params["search_query"] || ""
        trigger_match_counting(socket, search_query)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("save_alert", params, socket) do
    user = socket.assigns.current_scope.user
    channel_ids = Map.get(params, "channel_ids", [])

    attrs = %{
      name: params["name"],
      description: params["description"],
      search_query: params["search_query"],
      alert_type: params["alert_type"],
      velocity_threshold: parse_int(params["velocity_threshold"]),
      velocity_window_seconds: parse_int(params["velocity_window_seconds"]),
      cooldown_seconds: parse_int(params["cooldown_seconds"])
    }

    result =
      if socket.assigns.editing_alert do
        Alerts.update_alert(socket.assigns.editing_alert, attrs, channel_ids)
      else
        Alerts.create_alert(user, attrs, channel_ids)
      end

    case result do
      {:ok, alert} ->
        alerts =
          if socket.assigns.editing_alert do
            Enum.map(socket.assigns.alerts, fn a ->
              if a.id == alert.id, do: alert, else: a
            end)
          else
            [alert | socket.assigns.alerts]
          end

        {:noreply,
         socket
         |> assign(:alerts, alerts)
         |> assign(:show_form, false)
         |> assign(:editing_alert, nil)
         |> reset_form()
         |> put_flash(
           :info,
           if(socket.assigns.editing_alert, do: "Alert updated", else: "Alert created")
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, format_errors(changeset))}
    end
  end

  def handle_event("edit_alert", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Alerts.get_alert(user, String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Alert not found")}

      alert ->
        form_data = %{
          "name" => alert.name,
          "description" => alert.description || "",
          "search_query" => alert.search_query,
          "alert_type" => alert.alert_type,
          "velocity_threshold" => to_string(alert.velocity_threshold || 10),
          "velocity_window_seconds" => to_string(alert.velocity_window_seconds || 300),
          "cooldown_seconds" => to_string(alert.cooldown_seconds),
          "channel_ids" => Enum.map(alert.notification_channels, &to_string(&1.id))
        }

        socket =
          socket
          |> assign(:show_form, true)
          |> assign(:editing_alert, alert)
          |> assign(:form, to_form(form_data))
          |> trigger_match_counting(alert.search_query)

        {:noreply, socket}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Alerts.get_alert(user, String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Alert not found")}

      alert ->
        case Alerts.toggle_alert(alert) do
          {:ok, updated} ->
            alerts =
              Enum.map(socket.assigns.alerts, fn a ->
                if a.id == updated.id, do: %{a | enabled: updated.enabled}, else: a
              end)

            {:noreply, assign(socket, :alerts, alerts)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update alert")}
        end
    end
  end

  def handle_event("delete_alert", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Alerts.get_alert(user, String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Alert not found")}

      alert ->
        case Alerts.delete_alert(alert) do
          {:ok, _} ->
            alerts = Enum.reject(socket.assigns.alerts, &(&1.id == alert.id))

            {:noreply,
             socket
             |> assign(:alerts, alerts)
             |> put_flash(:info, "Alert deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete alert")}
        end
    end
  end

  def handle_event("toggle_history", %{"id" => id}, socket) do
    alert_id = String.to_integer(id)

    if socket.assigns.expanded_history == alert_id do
      {:noreply,
       socket
       |> assign(:expanded_history, nil)
       |> assign(:history_entries, [])}
    else
      user = socket.assigns.current_scope.user

      case Alerts.get_alert(user, alert_id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Alert not found")}

        alert ->
          history = Alerts.list_alert_history(alert, limit: 20)

          {:noreply,
           socket
           |> assign(:expanded_history, alert_id)
           |> assign(:history_entries, history)}
      end
    end
  end

  @impl true
  def handle_info({:match_counts, counts}, socket) do
    {:noreply,
     socket
     |> assign(:match_counts, counts)
     |> assign(:counting, false)}
  end

  defp trigger_match_counting(socket, "") do
    socket
    |> assign(:match_counts, nil)
    |> assign(:counting, false)
  end

  defp trigger_match_counting(socket, search_query) do
    pid = self()

    Task.start(fn ->
      counts = %{
        hour: Logs.count_matches(search_query, 3600),
        day: Logs.count_matches(search_query, 86400),
        week: Logs.count_matches(search_query, 604_800)
      }

      send(pid, {:match_counts, counts})
    end)

    assign(socket, :counting, true)
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(val) when is_binary(val), do: String.to_integer(val)
  defp parse_int(val) when is_integer(val), do: val

  defp format_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_count(n), do: to_string(n)

  defp format_alert_type("any_match"), do: "Any Match"
  defp format_alert_type("velocity"), do: "Velocity"
  defp format_alert_type(other), do: other

  defp format_trigger_type("any_match"), do: "Log Match"
  defp format_trigger_type("velocity"), do: "Velocity Threshold"
  defp format_trigger_type(other), do: other

  defp format_trigger_data("any_match", data) do
    "#{data["log_level"]}: #{data["log_message"]}"
  end

  defp format_trigger_data("velocity", data) do
    "#{data["count"]} matches (threshold: #{data["threshold"]})"
  end

  defp format_trigger_data(_, _), do: ""

  defp format_window(60), do: "1 min"
  defp format_window(300), do: "5 min"
  defp format_window(900), do: "15 min"
  defp format_window(1800), do: "30 min"
  defp format_window(3600), do: "1 hour"
  defp format_window(14400), do: "4 hours"
  defp format_window(86400), do: "24 hours"
  defp format_window(s), do: "#{s}s"

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

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
