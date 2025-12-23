defmodule WhisperLogsWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use WhisperLogsWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="h-screen bg-bg-base text-text-primary flex flex-col overflow-hidden">
      <header class="flex-shrink-0 border-b border-border-default bg-bg-elevated">
        <div class="px-4 sm:px-6 lg:px-8 h-10 flex items-center justify-between">
          <div class="flex items-center gap-4">
            <a
              href="/"
              class="text-sm text-text-primary hover:text-white transition-colors font-semibold tracking-tight"
            >
              WhisperLogs
            </a>

            <%= if @current_scope do %>
              <nav class="flex items-center gap-0.5">
                <.link
                  navigate={~p"/"}
                  class="px-2 py-1 rounded text-smaller font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface transition-colors"
                >
                  Logs
                </.link>
                <.link
                  navigate={~p"/sources"}
                  class="px-2 py-1 rounded text-smaller font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface transition-colors"
                >
                  Sources
                </.link>
                <.link
                  navigate={~p"/metrics"}
                  class="px-2 py-1 rounded text-smaller font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface transition-colors"
                >
                  Metrics
                </.link>
                <.link
                  navigate={~p"/alerts"}
                  class="px-2 py-1 rounded text-smaller font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface transition-colors"
                >
                  Alerts
                </.link>
              </nav>
            <% end %>
          </div>

          <div class="flex items-center gap-3">
            <%= if @current_scope do %>
              <span class="text-xs text-text-tertiary">{@current_scope.user.email}</span>
              <.link
                href={~p"/users/log-out"}
                method="delete"
                class="text-xs font-medium text-text-secondary hover:text-text-primary transition-colors"
              >
                Log out
              </.link>
            <% else %>
              <.link
                navigate={~p"/users/log-in"}
                class="text-xs font-medium text-text-secondary hover:text-text-primary transition-colors"
              >
                Log in
              </.link>
            <% end %>
          </div>
        </div>
      </header>

      <main class="flex-1 flex flex-col min-h-0">
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
