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
    <div class="h-dvh md:h-screen bg-bg-base text-text-primary flex flex-col overflow-hidden">
      <header class="flex-shrink-0 border-b border-border-default bg-bg-elevated">
        <div class="px-3 py-2 md:px-6 md:py-0 lg:px-8 md:h-10 flex items-start md:items-center justify-between gap-3">
          <div class="min-w-0 flex flex-1 flex-col gap-2 md:flex-row md:items-center md:gap-4">
            <a
              href="/"
              class="flex w-fit items-center gap-1.5 text-sm text-text-primary hover:text-white transition-colors font-semibold tracking-tight"
            >
              <.icon name="hero-chat-bubble-bottom-center-text-solid" class="size-4" /> WhisperLogs
            </a>

            <%= if @current_scope do %>
              <nav class="-mx-1 flex w-[calc(100vw-1.5rem)] items-center gap-0.5 overflow-x-auto px-1 pb-0.5 md:mx-0 md:w-auto md:overflow-visible md:px-0 md:pb-0">
                <.link
                  navigate={~p"/"}
                  class="shrink-0 px-2 py-1 rounded text-smaller font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface transition-colors"
                >
                  Logs
                </.link>
                <.link
                  navigate={~p"/sources"}
                  class="shrink-0 px-2 py-1 rounded text-smaller font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface transition-colors"
                >
                  Sources
                </.link>
                <.link
                  navigate={~p"/metrics"}
                  class="shrink-0 px-2 py-1 rounded text-smaller font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface transition-colors"
                >
                  Metrics
                </.link>
                <.link
                  navigate={~p"/alerts"}
                  class="shrink-0 px-2 py-1 rounded text-smaller font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface transition-colors"
                >
                  Alerts
                </.link>
                <.link
                  navigate={~p"/exports"}
                  class="shrink-0 px-2 py-1 rounded text-smaller font-medium text-text-secondary hover:text-text-primary hover:bg-bg-surface transition-colors"
                >
                  Exports
                </.link>
              </nav>
            <% end %>
          </div>

          <%!-- Hide email/logout in SQLite single-user mode --%>
          <%= unless WhisperLogs.DbAdapter.sqlite?() do %>
            <div class="flex shrink-0 items-center gap-3">
              <%= if @current_scope do %>
                <span class="hidden text-xs text-text-tertiary md:inline">{@current_scope.user.email}</span>
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
          <% end %>
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
