defmodule WhisperLogsWeb.ApiKeysLive do
  use WhisperLogsWeb, :live_view

  alias WhisperLogs.Accounts

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    api_keys = Accounts.list_api_keys(user)

    {:ok,
     socket
     |> assign(:page_title, "API Keys")
     |> assign(:api_keys, api_keys)
     |> assign(:revealed_key_id, nil)
     |> assign(:form, to_form(%{"name" => "", "source" => ""}))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-4xl mx-auto px-6 py-8">
        <.header>
          API Keys
          <:subtitle>
            Manage API keys for log ingestion. Each key is tied to a source identifier.
          </:subtitle>
        </.header>

        <div class="mt-8 bg-bg-elevated border border-border-default rounded-lg p-6">
          <h3 class="text-lg font-semibold text-text-primary mb-4">Create New API Key</h3>
          <.form for={@form} id="api-key-form" phx-submit="create" class="space-y-4">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input
                field={@form[:name]}
                type="text"
                label="Name"
                placeholder="e.g., Production Server"
              />
              <.input
                field={@form[:source]}
                type="text"
                label="Source"
                placeholder="e.g., my-app-prod"
              />
            </div>
            <p class="text-sm text-text-tertiary">
              Source must be lowercase letters, numbers, hyphens, and underscores only.
            </p>
            <.button variant="primary" phx-disable-with="Creating...">Create API Key</.button>
          </.form>
        </div>

        <div class="mt-8">
          <h3 class="text-lg font-semibold text-text-primary mb-4">Your API Keys</h3>

          <div class="space-y-3">
            <%= if @api_keys == [] do %>
              <div class="flex flex-col items-center justify-center py-12 text-text-tertiary">
                <.icon name="hero-key" class="size-10 mb-3 opacity-50" />
                <p class="text-text-secondary font-medium">No API keys yet</p>
                <p class="mt-1 text-sm">Create one above to start ingesting logs.</p>
              </div>
            <% end %>
            <div
              :for={api_key <- @api_keys}
              id={"api-key-row-#{api_key.id}"}
              class="bg-bg-elevated border border-border-default rounded-lg p-4 hover:border-border-subtle transition-colors"
            >
              <div class="flex items-center justify-between">
                <div class="flex-1">
                  <div class="flex items-center gap-3">
                    <span class="font-medium text-text-primary">{api_key.name}</span>
                    <span class="px-2 py-0.5 bg-bg-surface border border-border-default rounded text-xs text-text-secondary font-mono">
                      {api_key.source}
                    </span>
                  </div>
                  <div class="mt-1.5 flex items-center gap-4 text-sm text-text-tertiary">
                    <span>Created {Calendar.strftime(api_key.inserted_at, "%b %d, %Y")}</span>
                    <%= if api_key.last_used_at do %>
                      <span>Last used {Calendar.strftime(api_key.last_used_at, "%b %d, %Y")}</span>
                    <% else %>
                      <span class="text-text-tertiary/60">Never used</span>
                    <% end %>
                  </div>
                </div>
                <div class="flex items-center gap-2">
                  <button
                    type="button"
                    phx-click="toggle_reveal"
                    phx-value-id={api_key.id}
                    class="px-3 py-1.5 text-sm font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface rounded-lg transition-colors"
                  >
                    {if @revealed_key_id == api_key.id, do: "Hide", else: "Reveal"}
                  </button>
                  <button
                    type="button"
                    phx-click="revoke"
                    phx-value-id={api_key.id}
                    data-confirm="Are you sure you want to revoke this API key? This cannot be undone."
                    class="px-3 py-1.5 text-sm font-medium text-red-400 hover:text-red-300 hover:bg-red-500/10 rounded-lg transition-colors"
                  >
                    Revoke
                  </button>
                </div>
              </div>
              <%= if @revealed_key_id == api_key.id do %>
                <div class="mt-4 flex items-center gap-2">
                  <code
                    id={"api-key-#{api_key.id}"}
                    class="flex-1 bg-bg-base border border-border-default px-4 py-2.5 rounded-lg font-mono text-sm text-text-primary select-all"
                  >
                    {api_key.key}
                  </code>
                  <button
                    type="button"
                    phx-hook="CopyToClipboard"
                    id={"copy-key-#{api_key.id}"}
                    data-copy-target={"api-key-#{api_key.id}"}
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
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("create", %{"name" => name, "source" => source}, socket) do
    user = socket.assigns.current_scope.user
    attrs = %{name: name, source: source}

    case Accounts.create_api_key(user, attrs) do
      {:ok, api_key} ->
        {:noreply,
         socket
         |> assign(:api_keys, [api_key | socket.assigns.api_keys])
         |> assign(:revealed_key_id, api_key.id)
         |> assign(:form, to_form(%{"name" => "", "source" => ""}))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, format_errors(changeset))
         |> assign(:form, to_form(changeset))}
    end
  end

  def handle_event("toggle_reveal", %{"id" => id}, socket) do
    new_id = if socket.assigns.revealed_key_id == id, do: nil, else: id
    {:noreply, assign(socket, :revealed_key_id, new_id)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.get_api_key(user, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "API key not found")}

      api_key ->
        case Accounts.revoke_api_key(api_key) do
          {:ok, _} ->
            api_keys = Enum.reject(socket.assigns.api_keys, &(&1.id == api_key.id))

            {:noreply,
             socket
             |> assign(:api_keys, api_keys)
             |> put_flash(:info, "API key revoked successfully")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to revoke API key")}
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
