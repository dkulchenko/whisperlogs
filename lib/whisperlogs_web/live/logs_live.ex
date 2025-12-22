defmodule WhisperLogsWeb.LogsLive do
  use WhisperLogsWeb, :live_view

  alias Phoenix.LiveView.JS
  alias WhisperLogs.Logs

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Logs.subscribe()
    end

    sources = Logs.list_sources()
    logs = Logs.list_logs(limit: 100) |> Enum.reverse()

    {:ok,
     socket
     |> assign(:page_title, "Logs")
     |> assign(:sources, sources)
     |> assign(:filters, default_filters())
     |> assign(:live_tail, true)
     |> stream(:logs, logs)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex-1 flex flex-col min-h-0 bg-bg-base">
        <%!-- Log list --%>
        <div class="flex-1 overflow-y-auto" id="log-container" phx-hook=".AutoScroll">
          <div id="logs" phx-update="stream" class="divide-y divide-border-subtle">
            <div class="hidden only:flex flex-col items-center justify-center py-20 text-text-tertiary">
              <.icon name="hero-document-text" class="size-12 mb-4 opacity-50" />
              <p class="text-lg font-medium text-text-secondary">No logs yet</p>
              <p class="mt-1 text-sm">Start sending logs to see them here.</p>
            </div>
            <div
              :for={{dom_id, log} <- @streams.logs}
              id={dom_id}
              class="group hover:bg-bg-elevated/50 cursor-pointer transition-colors"
              phx-click={JS.toggle(to: "##{dom_id}-details")}
            >
              <div class="px-4 py-1.5 flex items-center gap-3 font-mono text-xs">
                <%!-- Timestamp --%>
                <span class="flex-shrink-0 text-text-tertiary text-xs tabular-nums">
                  {format_timestamp(log.timestamp)}
                </span>

                <%!-- Level badge --%>
                <span class={[
                  "flex-shrink-0 px-2 py-0.5 rounded text-xs font-semibold uppercase tracking-wide",
                  level_badge(log.level)
                ]}>
                  {String.slice(log.level, 0, 3)}
                </span>

                <%!-- Source --%>
                <span class="flex-shrink-0 text-text-tertiary text-xs font-medium">
                  {log.source}
                </span>

                <%!-- Message + Metadata --%>
                <span class="flex-1 break-all leading-relaxed">
                  <span class="text-text-primary">{log.message}</span>
                  <%= if log.request_id || log.metadata != %{} do %>
                    <span class="text-text-tertiary ml-2">
                      <%= if log.request_id do %>
                        <span class="text-purple-400">request_id</span><span class="text-text-tertiary">=</span><span class="text-purple-300">{log.request_id}</span>
                      <% end %>
                      <span :for={{key, value} <- log.metadata}>
                        <span class="text-blue-400 ml-2">{key}</span><span class="text-text-tertiary">=</span><span class="text-blue-300">{format_metadata_value(value)}</span>
                      </span>
                    </span>
                  <% end %>
                </span>

                <%!-- Expand indicator --%>
                <.icon name="hero-chevron-down" class="flex-shrink-0 size-4 text-text-tertiary opacity-0 group-hover:opacity-100 transition-opacity" />
              </div>

              <%!-- Expanded details --%>
              <div id={"#{dom_id}-details"} class="hidden border-t border-border-subtle bg-bg-surface/50 px-4 py-4 ml-[72px] mr-4 mb-2 rounded-lg">
                <div class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-xs">
                  <span class="text-text-tertiary font-medium">Timestamp</span>
                  <span class="text-text-secondary font-mono">{DateTime.to_iso8601(log.timestamp)}</span>
                  <span class="text-text-tertiary font-medium">Source</span>
                  <span class="text-text-secondary font-mono">{log.source}</span>
                  <%= if log.request_id do %>
                    <span class="text-text-tertiary font-medium">Request ID</span>
                    <span class="text-text-secondary font-mono">{log.request_id}</span>
                  <% end %>
                </div>
                <%= if log.metadata != %{} do %>
                  <div class="mt-4">
                    <span class="text-xs text-text-tertiary font-medium">Metadata</span>
                    <pre class="mt-2 bg-bg-base border border-border-default rounded-lg p-4 text-xs text-text-secondary overflow-x-auto"><code>{Jason.encode!(log.metadata, pretty: true)}</code></pre>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <%!-- Bottom filter bar --%>
        <form id="filters-form" phx-change="filter" phx-submit="filter" class="flex-shrink-0 border-t border-border-default bg-bg-elevated px-4 py-2.5">
          <div class="flex items-center gap-4">
            <%!-- Search --%>
            <div class="relative flex-1">
              <.icon name="hero-magnifying-glass" class="absolute left-3 top-1/2 -translate-y-1/2 size-4 text-text-tertiary" />
              <input
                type="text"
                name="search"
                value={@filters.search}
                phx-debounce="300"
                placeholder="Search messages..."
                class="w-full bg-bg-surface border border-border-default rounded-lg pl-9 pr-3 py-1.5 text-sm text-text-primary placeholder:text-text-tertiary focus:outline-none focus:border-text-tertiary transition-colors"
              />
            </div>

            <%!-- Level filter --%>
            <div class="flex gap-1.5">
              <label
                :for={level <- ~w(debug info warning error)}
                class={[
                  "px-2.5 py-1.5 rounded-lg text-xs font-medium cursor-pointer transition-all border",
                  level_selected?(@filters.levels, level) && level_filter_bg(level),
                  !level_selected?(@filters.levels, level) &&
                    "bg-bg-surface border-border-default text-text-tertiary hover:text-text-secondary hover:border-border-subtle"
                ]}
              >
                <input
                  type="checkbox"
                  name={"levels[]"}
                  value={level}
                  checked={level_selected?(@filters.levels, level)}
                  class="sr-only"
                />
                {String.upcase(level)}
              </label>
            </div>

            <%!-- Source filter --%>
            <%= if @sources != [] do %>
              <select
                name="source"
                class="bg-bg-surface border border-border-default rounded-lg px-3 py-1.5 text-sm text-text-primary focus:outline-none focus:border-text-tertiary"
              >
                <option value="">All sources</option>
                <option
                  :for={source <- @sources}
                  value={source}
                  selected={@filters.source == source}
                >
                  {source}
                </option>
              </select>
            <% end %>

            <%!-- Live tail toggle --%>
            <button
              type="button"
              phx-click="toggle_live_tail"
              class={[
                "inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium transition-all border",
                @live_tail && "bg-accent-purple border-accent-purple text-white",
                !@live_tail && "bg-bg-surface border-border-default text-text-secondary hover:text-text-primary hover:border-border-subtle"
              ]}
            >
              <%= if @live_tail do %>
                <span class="relative flex h-1.5 w-1.5">
                  <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-white opacity-75"></span>
                  <span class="relative inline-flex rounded-full h-1.5 w-1.5 bg-white"></span>
                </span>
              <% else %>
                <.icon name="hero-pause" class="size-3.5" />
              <% end %>
              {if @live_tail, do: "Live", else: "Paused"}
            </button>

            <%!-- Clear filters --%>
            <button
              type="button"
              phx-click="clear_filters"
              class="px-3 py-1.5 rounded-lg text-xs font-medium text-text-tertiary hover:text-text-primary hover:bg-bg-surface transition-colors"
            >
              Clear
            </button>
          </div>
        </form>
      </div>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoScroll">
      const SCROLL_TOLERANCE = 40

      export default {
        mounted() {
          this.isNearBottom = true
          this.el.addEventListener("scroll", () => {
            const { scrollTop, scrollHeight, clientHeight } = this.el
            this.isNearBottom = scrollHeight - scrollTop - clientHeight < SCROLL_TOLERANCE
          })
          // Initial scroll to bottom
          this.el.scrollTop = this.el.scrollHeight
        },
        updated() {
          if (this.isNearBottom) {
            this.el.scrollTop = this.el.scrollHeight
          }
        }
      }
    </script>
    """
  end

  @impl true
  def handle_event("filter", params, socket) do
    # Form sends all fields at once
    filters = %{
      search: params["search"] || "",
      source: params["source"] || "",
      levels: params["levels"] || []
    }

    logs = fetch_logs(filters)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> stream(:logs, logs, reset: true)}
  end

  def handle_event("toggle_live_tail", _params, socket) do
    {:noreply, assign(socket, :live_tail, !socket.assigns.live_tail)}
  end

  def handle_event("clear_filters", _params, socket) do
    filters = default_filters()
    logs = fetch_logs(filters)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> stream(:logs, logs, reset: true)}
  end

  @impl true
  def handle_info({:new_log, log}, socket) do
    if socket.assigns.live_tail and log_matches_filters?(log, socket.assigns.filters) do
      # Also refresh sources if this is a new source
      sources =
        if log.source in socket.assigns.sources do
          socket.assigns.sources
        else
          [log.source | socket.assigns.sources] |> Enum.sort()
        end

      {:noreply,
       socket
       |> assign(:sources, sources)
       |> stream_insert(:logs, log)}
    else
      {:noreply, socket}
    end
  end

  defp default_filters do
    %{
      search: "",
      source: "",
      levels: ~w(debug info warning error)
    }
  end

  defp fetch_logs(filters) do
    opts = [limit: 100]

    opts =
      if filters.search != "" do
        Keyword.put(opts, :search, filters.search)
      else
        opts
      end

    opts =
      if filters.source != "" do
        Keyword.put(opts, :sources, [filters.source])
      else
        opts
      end

    opts =
      if filters.levels != [] do
        Keyword.put(opts, :levels, filters.levels)
      else
        opts
      end

    Logs.list_logs(opts) |> Enum.reverse()
  end

  defp log_matches_filters?(log, filters) do
    level_match = filters.levels == [] or log.level in filters.levels
    source_match = filters.source == "" or log.source == filters.source

    search_match =
      filters.search == "" or
        String.contains?(String.downcase(log.message), String.downcase(filters.search))

    level_match and source_match and search_match
  end

  defp level_selected?(levels, level), do: level in levels

  # Filter button styling (when selected)
  defp level_filter_bg("debug"), do: "bg-bg-muted border-text-tertiary text-text-secondary"
  defp level_filter_bg("info"), do: "bg-blue-500/20 border-blue-500/50 text-blue-400"
  defp level_filter_bg("warning"), do: "bg-amber-500/20 border-amber-500/50 text-amber-400"
  defp level_filter_bg("error"), do: "bg-red-500/20 border-red-500/50 text-red-400"
  defp level_filter_bg(_), do: "bg-bg-muted border-border-default text-text-secondary"

  # Log entry badge styling
  defp level_badge("debug"), do: "bg-bg-muted text-text-tertiary"
  defp level_badge("info"), do: "bg-blue-500/20 text-blue-400"
  defp level_badge("warning"), do: "bg-amber-500/20 text-amber-400"
  defp level_badge("error"), do: "bg-red-500/20 text-red-400"
  defp level_badge(_), do: "bg-bg-muted text-text-tertiary"

  defp format_timestamp(dt) do
    # Convert UTC to PST/PDT (America/Los_Angeles)
    local_dt = DateTime.shift_zone!(dt, "America/Los_Angeles")
    Calendar.strftime(local_dt, "%m/%d %H:%M:%S.") <> format_milliseconds(local_dt)
  end

  defp format_milliseconds(%DateTime{microsecond: {us, _}}) do
    us |> div(1000) |> Integer.to_string() |> String.pad_leading(3, "0")
  end

  defp format_metadata_value(value) when is_binary(value), do: value
  defp format_metadata_value(value) when is_number(value), do: to_string(value)
  defp format_metadata_value(value) when is_boolean(value), do: to_string(value)
  defp format_metadata_value(value) when is_nil(value), do: "null"
  defp format_metadata_value(value), do: Jason.encode!(value)
end
