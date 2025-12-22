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
    logs = Logs.list_logs(limit: 100)

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
      <div class="h-full flex flex-col bg-zinc-950">
        <%!-- Header with filters --%>
        <form id="filters-form" phx-change="filter" phx-submit="filter" class="flex-shrink-0 border-b border-zinc-800 bg-zinc-900 p-4">
          <div class="flex flex-wrap gap-4 items-end">
            <%!-- Search --%>
            <div class="flex-1 min-w-64">
              <label class="block text-xs text-zinc-500 mb-1">Search</label>
              <input
                type="text"
                name="search"
                value={@filters.search}
                phx-debounce="300"
                placeholder="Search messages..."
                class="w-full bg-zinc-800 border-zinc-700 rounded px-3 py-2 text-sm text-zinc-100 placeholder-zinc-500 focus:ring-1 focus:ring-blue-500 focus:border-blue-500"
              />
            </div>

            <%!-- Level filter --%>
            <div>
              <label class="block text-xs text-zinc-500 mb-1">Levels</label>
              <div class="flex gap-2">
                <label
                  :for={level <- ~w(debug info warning error)}
                  class={[
                    "px-2 py-1.5 rounded text-xs font-medium cursor-pointer transition-colors",
                    level_selected?(@filters.levels, level) && level_bg(level),
                    !level_selected?(@filters.levels, level) &&
                      "bg-zinc-800 text-zinc-500 hover:bg-zinc-700"
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
            </div>

            <%!-- Source filter --%>
            <%= if @sources != [] do %>
              <div>
                <label class="block text-xs text-zinc-500 mb-1">Source</label>
                <select
                  name="source"
                  class="bg-zinc-800 border-zinc-700 rounded px-3 py-2 text-sm text-zinc-100 focus:ring-1 focus:ring-blue-500"
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
              </div>
            <% end %>

            <%!-- Live tail toggle --%>
            <div>
              <label class="block text-xs text-zinc-500 mb-1">Live</label>
              <button
                type="button"
                phx-click="toggle_live_tail"
                class={[
                  "px-3 py-2 rounded text-sm font-medium transition-colors",
                  @live_tail && "bg-emerald-600 text-white",
                  !@live_tail && "bg-zinc-800 text-zinc-400 hover:bg-zinc-700"
                ]}
              >
                <%= if @live_tail do %>
                  <span class="inline-block w-2 h-2 bg-emerald-300 rounded-full mr-1.5 animate-pulse" />
                <% end %>
                {if @live_tail, do: "Live", else: "Paused"}
              </button>
            </div>

            <%!-- Clear filters --%>
            <button
              type="button"
              phx-click="clear_filters"
              class="px-3 py-2 rounded text-sm text-zinc-400 hover:text-zinc-200 hover:bg-zinc-800 transition-colors"
            >
              Clear
            </button>
          </div>
        </form>

        <%!-- Log list --%>
        <div class="flex-1 overflow-y-auto" id="log-container">
          <div id="logs" phx-update="stream" class="divide-y divide-zinc-800/50">
            <div class="hidden only:flex items-center justify-center py-16 text-zinc-500">
              No logs yet. Start sending logs to see them here.
            </div>
            <div
              :for={{dom_id, log} <- @streams.logs}
              id={dom_id}
              class="group hover:bg-zinc-900/50 cursor-pointer"
              phx-click={JS.toggle(to: "##{dom_id}-details")}
            >
              <div class="px-4 py-2 flex items-start gap-3 font-mono text-sm">
                <%!-- Timestamp --%>
                <span class="flex-shrink-0 text-zinc-500 text-xs">
                  {format_timestamp(log.timestamp)}
                </span>

                <%!-- Level badge --%>
                <span class={[
                  "flex-shrink-0 px-1.5 py-0.5 rounded text-xs font-medium",
                  level_bg(log.level)
                ]}>
                  {String.upcase(String.slice(log.level, 0, 3))}
                </span>

                <%!-- Source --%>
                <span class="flex-shrink-0 text-zinc-600 text-xs">
                  [{log.source}]
                </span>

                <%!-- Message --%>
                <span class="flex-1 text-zinc-200 break-all">
                  {log.message}
                </span>

                <%!-- Request ID --%>
                <%= if log.request_id do %>
                  <span class="flex-shrink-0 text-zinc-600 text-xs">
                    {String.slice(log.request_id, 0, 8)}
                  </span>
                <% end %>
              </div>

              <%!-- Expanded details (toggled client-side) --%>
              <div id={"#{dom_id}-details"} class="hidden px-4 pb-3 ml-16 space-y-2">
                <div class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-xs">
                  <span class="text-zinc-500">Timestamp</span>
                  <span class="text-zinc-300 font-mono">{DateTime.to_iso8601(log.timestamp)}</span>
                  <span class="text-zinc-500">Source</span>
                  <span class="text-zinc-300 font-mono">{log.source}</span>
                  <%= if log.request_id do %>
                    <span class="text-zinc-500">Request ID</span>
                    <span class="text-zinc-300 font-mono">{log.request_id}</span>
                  <% end %>
                </div>
                <%= if log.metadata != %{} do %>
                  <div>
                    <span class="text-xs text-zinc-500">Metadata</span>
                    <pre class="mt-1 bg-zinc-900 rounded p-3 text-xs text-zinc-400 overflow-x-auto"><code phx-no-curly-interpolation>{Jason.encode!(log.metadata, pretty: true)}</code></pre>
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
       |> stream_insert(:logs, log, at: 0)}
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

    Logs.list_logs(opts)
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

  defp level_bg("debug"), do: "bg-zinc-700 text-zinc-300"
  defp level_bg("info"), do: "bg-blue-900 text-blue-200"
  defp level_bg("warning"), do: "bg-yellow-900 text-yellow-200"
  defp level_bg("error"), do: "bg-red-900 text-red-200"
  defp level_bg(_), do: "bg-zinc-700 text-zinc-300"

  defp format_timestamp(dt) do
    Calendar.strftime(dt, "%H:%M:%S.") <> format_microseconds(dt)
  end

  defp format_microseconds(%DateTime{microsecond: {us, _}}) do
    us |> Integer.to_string() |> String.pad_leading(6, "0") |> String.slice(0, 3)
  end
end
