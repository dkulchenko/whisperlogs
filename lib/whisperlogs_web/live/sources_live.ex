defmodule WhisperLogsWeb.SourcesLive do
  use WhisperLogsWeb, :live_view

  alias WhisperLogs.Accounts

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    sources = Accounts.list_sources(user)
    next_port = Accounts.next_available_syslog_port()

    {:ok,
     socket
     |> assign(:page_title, "Sources")
     |> assign(:sources, sources)
     |> assign(:revealed_key_id, nil)
     |> assign(:editing_source, nil)
     |> assign(:http_form, to_form(%{"name" => "", "source" => ""}))
     |> assign(
       :syslog_form,
       to_form(%{
         "name" => "",
         "source" => "",
         "port" => to_string(next_port),
         "transport" => "udp",
         "auto_register_hosts" => "true"
       })
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex-1 overflow-y-auto">
        <div class="max-w-4xl mx-auto px-6 py-8">
        <.header>
          Sources
          <:subtitle>
            Configure log ingestion sources. Create HTTP sources for API-based logging
            or Syslog sources for receiving syslog messages.
          </:subtitle>
        </.header>

        <div class="mt-8 grid gap-6 lg:grid-cols-2">
          <%!-- HTTP Source Form --%>
          <div
            :if={@editing_source == nil || @editing_source.type == "http"}
            class="bg-bg-elevated border border-border-default rounded-lg p-6"
          >
            <div class="flex items-center gap-2 mb-4">
              <.icon name="hero-globe-alt" class="size-5 text-accent-purple" />
              <h3 class="text-lg font-semibold text-text-primary">
                {if @editing_source && @editing_source.type == "http",
                  do: "Edit HTTP Source",
                  else: "HTTP Source"}
              </h3>
            </div>
            <.form for={@http_form} id="http-source-form" phx-submit="save_http" class="space-y-4">
              <.input
                field={@http_form[:name]}
                type="text"
                label="Name"
                placeholder="e.g., Production Server"
              />
              <.input
                field={@http_form[:source]}
                type="text"
                label="Source ID"
                placeholder="e.g., my-app-prod"
                disabled={@editing_source != nil}
              />
              <p :if={@editing_source == nil} class="text-sm text-text-tertiary">
                Use the generated API key with POST /api/v1/logs
              </p>
              <div class="flex gap-3">
                <.button
                  variant="primary"
                  phx-disable-with={if @editing_source, do: "Saving...", else: "Creating..."}
                >
                  {if @editing_source && @editing_source.type == "http",
                    do: "Save Changes",
                    else: "Create HTTP Source"}
                </.button>
                <button
                  :if={@editing_source && @editing_source.type == "http"}
                  type="button"
                  phx-click="cancel_edit"
                  class="px-4 py-2 text-sm font-medium text-text-secondary hover:text-text-primary rounded-lg transition-colors"
                >
                  Cancel
                </button>
              </div>
            </.form>
          </div>

          <%!-- Syslog Source Form --%>
          <div
            :if={@editing_source == nil || @editing_source.type == "syslog"}
            class="bg-bg-elevated border border-border-default rounded-lg p-6"
          >
            <div class="flex items-center gap-2 mb-4">
              <.icon name="hero-server" class="size-5 text-accent-purple" />
              <h3 class="text-lg font-semibold text-text-primary">
                {if @editing_source && @editing_source.type == "syslog",
                  do: "Edit Syslog Source",
                  else: "Syslog Source"}
              </h3>
            </div>
            <.form
              for={@syslog_form}
              id="syslog-source-form"
              phx-submit="save_syslog"
              class="space-y-4"
            >
              <.input
                field={@syslog_form[:name]}
                type="text"
                label="Name"
                placeholder="e.g., Network Devices"
              />
              <.input
                field={@syslog_form[:source]}
                type="text"
                label="Source ID"
                placeholder="e.g., network-logs"
                disabled={@editing_source != nil}
              />
              <div class="grid grid-cols-2 gap-3">
                <.input field={@syslog_form[:port]} type="number" label="Port" min="1024" max="65535" />
                <.input
                  field={@syslog_form[:transport]}
                  type="select"
                  label="Transport"
                  options={[{"UDP", "udp"}, {"TCP", "tcp"}, {"Both", "both"}]}
                />
              </div>
              <.input
                field={@syslog_form[:auto_register_hosts]}
                type="checkbox"
                label="Accept from any host"
              />
              <p :if={@editing_source == nil} class="text-sm text-text-tertiary">
                Supports RFC 3164 and RFC 5424 formats
              </p>
              <div class="flex gap-3">
                <.button
                  variant="primary"
                  phx-disable-with={if @editing_source, do: "Saving...", else: "Creating..."}
                >
                  {if @editing_source && @editing_source.type == "syslog",
                    do: "Save Changes",
                    else: "Create Syslog Source"}
                </.button>
                <button
                  :if={@editing_source && @editing_source.type == "syslog"}
                  type="button"
                  phx-click="cancel_edit"
                  class="px-4 py-2 text-sm font-medium text-text-secondary hover:text-text-primary rounded-lg transition-colors"
                >
                  Cancel
                </button>
              </div>
            </.form>
          </div>
        </div>

        <div class="mt-10">
          <h3 class="text-lg font-semibold text-text-primary mb-4">Your Sources</h3>

          <div class="space-y-3">
            <%= if @sources == [] do %>
              <div class="flex flex-col items-center justify-center py-12 text-text-tertiary">
                <.icon name="hero-server-stack" class="size-10 mb-3 opacity-50" />
                <p class="text-text-secondary font-medium">No sources yet</p>
                <p class="mt-1 text-sm">Create one above to start ingesting logs.</p>
              </div>
            <% end %>

            <div
              :for={source <- @sources}
              id={"source-row-#{source.id}"}
              class="bg-bg-elevated border border-border-default rounded-lg p-4 hover:border-border-subtle transition-colors"
            >
              <div class="flex items-center justify-between">
                <div class="flex-1">
                  <div class="flex items-center gap-3">
                    <%= if source.type == "http" do %>
                      <.icon name="hero-globe-alt" class="size-4 text-text-tertiary" />
                    <% else %>
                      <.icon name="hero-server" class="size-4 text-text-tertiary" />
                    <% end %>
                    <span class="font-medium text-text-primary">{source.name}</span>
                    <span class="px-2 py-0.5 bg-bg-surface border border-border-default rounded text-xs text-text-secondary font-mono">
                      {source.source}
                    </span>
                    <span class={[
                      "px-2 py-0.5 rounded text-xs font-medium",
                      source.type == "http" && "bg-blue-500/10 text-blue-400",
                      source.type == "syslog" && "bg-green-500/10 text-green-400"
                    ]}>
                      {String.upcase(source.type)}
                    </span>
                  </div>
                  <div class="mt-1.5 flex items-center gap-4 text-sm text-text-tertiary">
                    <span>Created {Calendar.strftime(source.inserted_at, "%b %d, %Y")}</span>
                    <%= if source.last_used_at do %>
                      <span>Last used {Calendar.strftime(source.last_used_at, "%b %d, %Y")}</span>
                    <% else %>
                      <span class="text-text-tertiary/60">Never used</span>
                    <% end %>
                    <%= if source.type == "syslog" do %>
                      <span class="font-mono text-accent-purple">
                        :{source.port} ({source.transport})
                      </span>
                    <% end %>
                  </div>
                </div>
                <div class="flex items-center gap-2">
                  <button
                    type="button"
                    phx-click="edit_source"
                    phx-value-id={source.id}
                    class="px-3 py-1.5 text-sm font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface rounded-lg transition-colors"
                  >
                    Edit
                  </button>
                  <%= if source.type == "http" do %>
                    <button
                      type="button"
                      phx-click="toggle_reveal"
                      phx-value-id={source.id}
                      class="px-3 py-1.5 text-sm font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface rounded-lg transition-colors"
                    >
                      {if @revealed_key_id == source.id, do: "Hide", else: "Reveal Key"}
                    </button>
                  <% end %>
                  <button
                    type="button"
                    phx-click="revoke"
                    phx-value-id={source.id}
                    data-confirm={"Are you sure you want to revoke this #{source.type} source? This cannot be undone."}
                    class="px-3 py-1.5 text-sm font-medium text-red-400 hover:text-red-300 hover:bg-red-500/10 rounded-lg transition-colors"
                  >
                    Revoke
                  </button>
                </div>
              </div>
              <%= if source.type == "http" and @revealed_key_id == source.id do %>
                <div class="mt-4 flex items-center gap-2">
                  <code
                    id={"source-key-#{source.id}"}
                    class="flex-1 bg-bg-base border border-border-default px-4 py-2.5 rounded-lg font-mono text-sm text-text-primary select-all"
                  >
                    {source.key}
                  </code>
                  <button
                    type="button"
                    phx-hook="CopyToClipboard"
                    id={"copy-key-#{source.id}"}
                    data-copy-target={"source-key-#{source.id}"}
                    class="px-4 py-2.5 bg-bg-surface hover:bg-bg-muted border border-border-default rounded-lg text-sm font-medium text-text-primary transition-colors"
                  >
                    Copy
                  </button>
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
  def handle_event("save_http", params, socket) do
    user = socket.assigns.current_scope.user
    name = params["name"]

    if socket.assigns.editing_source && socket.assigns.editing_source.type == "http" do
      # Update mode
      case Accounts.update_http_source(socket.assigns.editing_source, %{name: name}) do
        {:ok, updated_source} ->
          sources =
            Enum.map(socket.assigns.sources, fn s ->
              if s.id == updated_source.id, do: updated_source, else: s
            end)

          {:noreply,
           socket
           |> assign(:sources, sources)
           |> assign(:editing_source, nil)
           |> assign(:http_form, to_form(%{"name" => "", "source" => ""}))
           |> put_flash(:info, "Source updated successfully")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, format_errors(changeset))
           |> assign(:http_form, to_form(changeset))}
      end
    else
      # Create mode
      attrs = %{name: name, source: params["source"]}

      case Accounts.create_http_source(user, attrs) do
        {:ok, new_source} ->
          {:noreply,
           socket
           |> assign(:sources, [new_source | socket.assigns.sources])
           |> assign(:revealed_key_id, new_source.id)
           |> assign(:http_form, to_form(%{"name" => "", "source" => ""}))}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, format_errors(changeset))
           |> assign(:http_form, to_form(changeset))}
      end
    end
  end

  def handle_event("save_syslog", params, socket) do
    user = socket.assigns.current_scope.user

    if socket.assigns.editing_source && socket.assigns.editing_source.type == "syslog" do
      # Update mode
      attrs = %{
        name: params["name"],
        port: String.to_integer(params["port"]),
        transport: params["transport"],
        auto_register_hosts: params["auto_register_hosts"] == "true"
      }

      case Accounts.update_syslog_source(socket.assigns.editing_source, attrs) do
        {:ok, updated_source} ->
          sources =
            Enum.map(socket.assigns.sources, fn s ->
              if s.id == updated_source.id, do: updated_source, else: s
            end)

          next_port = Accounts.next_available_syslog_port()

          {:noreply,
           socket
           |> assign(:sources, sources)
           |> assign(:editing_source, nil)
           |> assign(
             :syslog_form,
             to_form(%{
               "name" => "",
               "source" => "",
               "port" => to_string(next_port),
               "transport" => "udp",
               "auto_register_hosts" => "true"
             })
           )
           |> put_flash(:info, "Source updated successfully")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, format_errors(changeset))
           |> assign(:syslog_form, to_form(changeset))}
      end
    else
      # Create mode
      attrs = %{
        name: params["name"],
        source: params["source"],
        port: String.to_integer(params["port"]),
        transport: params["transport"],
        auto_register_hosts: params["auto_register_hosts"] == "true"
      }

      case Accounts.create_syslog_source(user, attrs) do
        {:ok, new_source} ->
          next_port = Accounts.next_available_syslog_port()

          {:noreply,
           socket
           |> assign(:sources, [new_source | socket.assigns.sources])
           |> assign(
             :syslog_form,
             to_form(%{
               "name" => "",
               "source" => "",
               "port" => to_string(next_port),
               "transport" => "udp",
               "auto_register_hosts" => "true"
             })
           )
           |> put_flash(:info, "Syslog source created. Listening on port #{new_source.port}.")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, format_errors(changeset))
           |> assign(:syslog_form, to_form(changeset))}
      end
    end
  end

  def handle_event("toggle_reveal", %{"id" => id}, socket) do
    new_id = if socket.assigns.revealed_key_id == id, do: nil, else: id
    {:noreply, assign(socket, :revealed_key_id, new_id)}
  end

  def handle_event("edit_source", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.get_source(user, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Source not found")}

      %{type: "http"} = source ->
        form_data = %{
          "name" => source.name,
          "source" => source.source
        }

        {:noreply,
         socket
         |> assign(:editing_source, source)
         |> assign(:http_form, to_form(form_data))}

      %{type: "syslog"} = source ->
        form_data = %{
          "name" => source.name,
          "source" => source.source,
          "port" => to_string(source.port),
          "transport" => source.transport,
          "auto_register_hosts" => to_string(source.auto_register_hosts)
        }

        {:noreply,
         socket
         |> assign(:editing_source, source)
         |> assign(:syslog_form, to_form(form_data))}
    end
  end

  def handle_event("cancel_edit", _, socket) do
    next_port = Accounts.next_available_syslog_port()

    {:noreply,
     socket
     |> assign(:editing_source, nil)
     |> assign(:http_form, to_form(%{"name" => "", "source" => ""}))
     |> assign(
       :syslog_form,
       to_form(%{
         "name" => "",
         "source" => "",
         "port" => to_string(next_port),
         "transport" => "udp",
         "auto_register_hosts" => "true"
       })
     )}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.get_source(user, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Source not found")}

      source ->
        case Accounts.revoke_source(source) do
          {:ok, _} ->
            sources = Enum.reject(socket.assigns.sources, &(&1.id == source.id))

            {:noreply,
             socket
             |> assign(:sources, sources)
             |> put_flash(:info, "Source revoked successfully")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to revoke source")}
        end
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
