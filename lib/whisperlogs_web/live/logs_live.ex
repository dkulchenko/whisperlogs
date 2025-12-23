defmodule WhisperLogsWeb.LogsLive do
  use WhisperLogsWeb, :live_view

  alias Phoenix.LiveView.JS
  alias WhisperLogs.Logs

  @per_page 100
  @max_logs @per_page * 5

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Logs.subscribe()
    end

    sources = Logs.list_sources()
    filters = default_filters()
    opts = filter_opts(filters) |> Keyword.put(:limit, @max_logs)
    logs = Logs.list_logs(opts) |> Enum.reverse()

    {cursor_top, cursor_bottom} = extract_cursors(logs)
    has_older? = cursor_top != nil and Logs.has_logs_before?(cursor_top, filter_opts(filters))

    {:ok,
     socket
     |> assign(:page_title, "Logs")
     |> assign(:sources, sources)
     |> assign(:filters, filters)
     |> assign(:live_tail, true)
     |> assign(:at_bottom?, true)
     |> assign(:far_from_bottom?, false)
     |> assign(:cursor_top, cursor_top)
     |> assign(:cursor_bottom, cursor_bottom)
     |> assign(:has_older?, has_older?)
     |> assign(:has_newer?, false)
     |> assign(:loading_older?, false)
     |> assign(:loading_newer?, false)
     |> assign(:scroll_to_date, "")
     |> assign(:scroll_to_time, "")
     |> stream(:logs, logs)}
  end

  defp extract_cursors([]), do: {nil, nil}

  defp extract_cursors(logs) do
    first = List.first(logs)
    last = List.last(logs)
    {{first.timestamp, first.id}, {last.timestamp, last.id}}
  end

  defp filter_opts(filters) do
    opts = []

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

    case filters.time_range do
      "3h" -> Keyword.put(opts, :from, DateTime.add(DateTime.utc_now(), -3, :hour))
      "12h" -> Keyword.put(opts, :from, DateTime.add(DateTime.utc_now(), -12, :hour))
      "24h" -> Keyword.put(opts, :from, DateTime.add(DateTime.utc_now(), -24, :hour))
      "7d" -> Keyword.put(opts, :from, DateTime.add(DateTime.utc_now(), -7, :day))
      "30d" -> Keyword.put(opts, :from, DateTime.add(DateTime.utc_now(), -30, :day))
      "all" -> opts
      _ -> Keyword.put(opts, :from, DateTime.add(DateTime.utc_now(), -3, :hour))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex-1 flex flex-col min-h-0 bg-bg-base relative">
        <%!-- Log list --%>
        <div
          class="flex-1 overflow-y-auto relative"
          id="log-container"
          phx-hook=".InfiniteScroll"
          data-has-older={to_string(@has_older?)}
          data-has-newer={to_string(@has_newer?)}
          style="overflow-anchor: auto;"
        >
          <%!-- Loading older indicator --%>
          <div
            :if={@loading_older?}
            class="sticky top-0 z-10 py-2 text-center bg-bg-base/80 backdrop-blur-sm border-b border-border-subtle"
          >
            <.icon name="hero-arrow-path" class="size-4 animate-spin inline-block text-text-tertiary" />
            <span class="ml-2 text-xs text-text-tertiary">Loading older logs...</span>
          </div>

          <div id="logs" phx-update="stream" class="divide-y divide-border-subtle">
            <div
              id="logs-empty"
              class="hidden only:flex flex-col items-center justify-center py-20 text-text-tertiary"
            >
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
              <div class="px-4 py-1 flex items-center gap-3 font-mono text-xs">
                <%!-- Timestamp --%>
                <span class="flex-shrink-0 text-text-tertiary text-xs tabular-nums">
                  {format_timestamp(log.timestamp)}
                </span>

                <%!-- Level badge --%>
                <span class={[
                  "flex-shrink-0 px-2 py-0.5 rounded text-xs font-semibold uppercase tracking-wide",
                  level_badge(log.level)
                ]}>
                  {level_abbrev(log.level)}
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

                <%!-- View in context button - only shows when filters are active --%>
                <button
                  :if={filters_active?(@filters)}
                  type="button"
                  phx-click="view-in-context"
                  phx-value-id={log.id}
                  phx-value-timestamp={DateTime.to_iso8601(log.timestamp)}
                  class="flex-shrink-0 p-1 rounded opacity-0 group-hover:opacity-100 hover:bg-bg-surface transition-all"
                  title="View in context"
                >
                  <.icon
                    name="hero-arrows-pointing-out"
                    class="size-4 text-text-tertiary hover:text-accent-purple"
                  />
                </button>

                <%!-- Expand indicator --%>
                <.icon
                  name="hero-chevron-down"
                  class="flex-shrink-0 size-4 text-text-tertiary opacity-0 group-hover:opacity-100 transition-opacity"
                />
              </div>

              <%!-- Expanded details --%>
              <div
                id={"#{dom_id}-details"}
                class="hidden border-t border-border-subtle bg-bg-surface/50 px-4 py-4 ml-[72px] mr-4 mb-2 rounded-lg"
              >
                <div class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-xs">
                  <span class="text-text-tertiary font-medium">Timestamp</span>
                  <span class="text-text-secondary font-mono">
                    {DateTime.to_iso8601(log.timestamp)}
                  </span>
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

          <%!-- Loading newer indicator --%>
          <div
            :if={@loading_newer?}
            class="sticky bottom-0 z-10 py-2 text-center bg-bg-base/80 backdrop-blur-sm border-t border-border-subtle"
          >
            <.icon name="hero-arrow-path" class="size-4 animate-spin inline-block text-text-tertiary" />
            <span class="ml-2 text-xs text-text-tertiary">Loading newer logs...</span>
          </div>
        </div>

        <%!-- Jump to latest button - positioned outside scrollable area --%>
        <button
          :if={@far_from_bottom? or @has_newer?}
          phx-click="jump-to-latest"
          class="absolute bottom-20 left-1/2 -translate-x-1/2 z-20 inline-flex items-center gap-2 px-4 py-2 bg-accent-purple text-white text-xs font-medium rounded-full shadow-lg hover:bg-accent-purple/90 transition-colors"
        >
          <.icon name="hero-arrow-down" class="size-4" /> Jump to latest
        </button>

        <%!-- Bottom filter bar --%>
        <form
          id="filters-form"
          phx-change="filter"
          phx-submit="filter"
          class="flex-shrink-0 border-t border-border-default bg-bg-elevated px-4 py-2.5"
        >
          <div class="flex items-center gap-4">
            <%!-- Search with time range --%>
            <div class="relative flex-1 flex items-center bg-bg-surface border border-border-default rounded-lg focus-within:border-text-tertiary transition-colors">
              <.icon
                name="hero-magnifying-glass"
                class="absolute left-3 top-1/2 -translate-y-1/2 size-4 text-text-tertiary"
              />
              <input
                type="text"
                name="search"
                value={@filters.search}
                phx-debounce="300"
                placeholder="Search messages..."
                class="flex-1 bg-transparent pl-9 pr-2 py-1.5 text-smaller text-text-primary placeholder:text-text-tertiary focus:outline-none"
              />
              <select
                name="time_range"
                class="bg-transparent border-l border-border-default px-2 py-1.5 text-smaller text-text-secondary focus:outline-none cursor-pointer"
              >
                <option value="3h" selected={@filters.time_range == "3h"}>Last 3h</option>
                <option value="12h" selected={@filters.time_range == "12h"}>Last 12h</option>
                <option value="24h" selected={@filters.time_range == "24h"}>Last 24h</option>
                <option value="7d" selected={@filters.time_range == "7d"}>Last 7d</option>
                <option value="30d" selected={@filters.time_range == "30d"}>Last 30d</option>
                <option value="all" selected={@filters.time_range == "all"}>All time</option>
              </select>
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
                  name="levels[]"
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
                class="bg-bg-surface border border-border-default rounded-lg px-3 py-1.5 text-smaller text-text-primary focus:outline-none focus:border-text-tertiary"
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

            <%!-- Scroll to time --%>
            <div class="relative">
              <button
                type="button"
                phx-click={JS.toggle(to: "#scroll-to-popover")}
                class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-smaller font-medium transition-all border bg-bg-surface border-border-default text-text-secondary hover:text-text-primary hover:border-border-subtle"
              >
                <.icon name="hero-clock" class="size-3.5" /> Scroll to
              </button>
              <div
                id="scroll-to-popover"
                class="hidden absolute bottom-full right-0 mb-2 p-3 bg-bg-elevated border border-border-default rounded-lg shadow-lg z-50"
                phx-click-away={JS.hide(to: "#scroll-to-popover")}
              >
                <div class="flex items-center gap-2">
                  <input
                    type="date"
                    id="scroll-to-date"
                    name="scroll_to_date"
                    value={@scroll_to_date}
                    phx-change="update-scroll-to"
                    class="bg-bg-surface border border-border-default rounded-lg px-2 py-1.5 text-smaller text-text-primary focus:outline-none focus:border-text-tertiary"
                  />
                  <input
                    type="time"
                    id="scroll-to-time"
                    name="scroll_to_time"
                    value={@scroll_to_time}
                    phx-change="update-scroll-to"
                    step="1"
                    class="bg-bg-surface border border-border-default rounded-lg px-2 py-1.5 text-smaller text-text-primary focus:outline-none focus:border-text-tertiary"
                  />
                  <button
                    type="button"
                    phx-click={JS.push("scroll-to-time") |> JS.hide(to: "#scroll-to-popover")}
                    class="px-3 py-1.5 bg-accent-purple text-white rounded-lg text-smaller font-medium hover:bg-accent-purple/90 transition-colors"
                  >
                    Go
                  </button>
                </div>
              </div>
            </div>

            <%!-- Live tail toggle --%>
            <button
              type="button"
              phx-click="toggle_live_tail"
              class={[
                "inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-smaller font-medium transition-all border",
                @live_tail && "bg-accent-purple border-accent-purple text-white",
                !@live_tail &&
                  "bg-bg-surface border-border-default text-text-secondary hover:text-text-primary hover:border-border-subtle"
              ]}
            >
              <%= if @live_tail do %>
                <span class="relative flex size-2">
                  <span class="live-wave absolute inset-0 rounded-full bg-white"></span>
                  <span class="live-wave-delayed absolute inset-0 rounded-full bg-white"></span>
                  <span class="relative inline-flex rounded-full size-2 bg-white"></span>
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
              class="px-3 py-1.5 rounded-lg text-smaller font-medium text-text-tertiary hover:text-text-primary hover:bg-bg-surface transition-colors"
            >
              Clear
            </button>
          </div>
        </form>
      </div>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".InfiniteScroll">
      const LOAD_THRESHOLD_PERCENT = 0.25  // load when within 25% of edge
      const BOTTOM_THRESHOLD = 100         // pixels from bottom to be considered "at bottom"
      const JUMP_BUTTON_THRESHOLD = 2800   // ~100 rows * 28px - show "Jump to latest" button

      export default {
        mounted() {
          this.loadingOlder = false
          this.loadingNewer = false
          this.isNearBottom = true
          this.wasNearBottom = true
          this.isFarFromBottom = false
          this.wasFarFromBottom = false
          this.lastScrollTop = this.el.scrollTop

          this.el.addEventListener("scroll", () => {
            const { scrollTop, scrollHeight, clientHeight } = this.el
            const distanceFromBottom = scrollHeight - scrollTop - clientHeight

            // Track scroll direction
            const isScrollingUp = scrollTop < this.lastScrollTop
            const isScrollingDown = scrollTop > this.lastScrollTop
            this.lastScrollTop = scrollTop

            // Near-bottom tracking for live tail (auto-scroll)
            this.isNearBottom = distanceFromBottom < BOTTOM_THRESHOLD

            // Far-from-bottom tracking for "Jump to latest" button
            this.isFarFromBottom = distanceFromBottom > JUMP_BUTTON_THRESHOLD

            // Notify server when scroll position changes relative to bottom
            if (!this.isNearBottom && this.wasNearBottom) {
              this.pushEvent("scroll-away", {})
            } else if (this.isNearBottom && !this.wasNearBottom) {
              this.pushEvent("scroll-to-bottom", {})
            }
            this.wasNearBottom = this.isNearBottom

            // Notify server when far from bottom changes (for jump button visibility)
            if (this.isFarFromBottom && !this.wasFarFromBottom) {
              this.pushEvent("far-from-bottom", {})
            } else if (!this.isFarFromBottom && this.wasFarFromBottom) {
              this.pushEvent("near-bottom", {})
            }
            this.wasFarFromBottom = this.isFarFromBottom

            // Calculate scroll position as percentage of total scrollable area
            const maxScroll = scrollHeight - clientHeight
            const scrollPercent = maxScroll > 0 ? scrollTop / maxScroll : 0

            const hasOlder = this.el.dataset.hasOlder === "true"
            const hasNewer = this.el.dataset.hasNewer === "true"

            // KEY FIX: Direction checking prevents infinite loops
            // Load older only when scrolling UP and in top 25%
            if (hasOlder && isScrollingUp && scrollPercent < LOAD_THRESHOLD_PERCENT && !this.loadingOlder) {
              this.loadingOlder = true
              this.pushEvent("load-older", {}, () => {
                this.loadingOlder = false
              })
            }

            // Load newer only when scrolling DOWN and in bottom 25%
            if (hasNewer && isScrollingDown && scrollPercent > (1 - LOAD_THRESHOLD_PERCENT) && !this.loadingNewer) {
              this.loadingNewer = true
              this.pushEvent("load-newer", {}, () => {
                this.loadingNewer = false
              })
            }
          })

          // Initial scroll to bottom
          this.el.scrollTop = this.el.scrollHeight

          // Handle Jump to Latest
          this.handleEvent("force-scroll-bottom", () => {
            this.el.scrollTop = this.el.scrollHeight
            this.isNearBottom = true
            this.wasNearBottom = true
            this.isFarFromBottom = false
            this.wasFarFromBottom = false
            this.lastScrollTop = this.el.scrollTop
          })

          // Handle View in Context - scroll to specific log and highlight
          this.handleEvent("scroll-to-log", ({ log_id }) => {
            requestAnimationFrame(() => {
              const logElement = document.getElementById(`logs-${log_id}`)
              if (logElement) {
                logElement.scrollIntoView({ behavior: "instant", block: "center" })
                logElement.classList.add("context-highlight")
                setTimeout(() => logElement.classList.remove("context-highlight"), 4000)
              }
            })
          })
        },

        updated() {
          // Auto-scroll to bottom for live tail only
          if (this.isNearBottom) {
            this.el.scrollTop = this.el.scrollHeight
            this.lastScrollTop = this.el.scrollTop
          }
          // NOTE: No flag resets here - callback handles it
          // NOTE: No setTimeout re-checks - direction check prevents loops
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
      levels: params["levels"] || [],
      time_range: params["time_range"] || socket.assigns.filters.time_range
    }

    logs = fetch_logs(filters)
    {cursor_top, cursor_bottom} = extract_cursors(logs)
    has_older? = cursor_top != nil and Logs.has_logs_before?(cursor_top, filter_opts(filters))

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:cursor_top, cursor_top)
     |> assign(:cursor_bottom, cursor_bottom)
     |> assign(:has_older?, has_older?)
     |> assign(:has_newer?, false)
     |> assign(:at_bottom?, true)
     |> assign(:far_from_bottom?, false)
     |> stream(:logs, logs, reset: true)}
  end

  def handle_event("toggle_live_tail", _params, socket) do
    {:noreply, assign(socket, :live_tail, !socket.assigns.live_tail)}
  end

  def handle_event("update-scroll-to", params, socket) do
    socket =
      socket
      |> assign(:scroll_to_date, params["scroll_to_date"] || socket.assigns.scroll_to_date)
      |> assign(:scroll_to_time, params["scroll_to_time"] || socket.assigns.scroll_to_time)

    {:noreply, socket}
  end

  def handle_event("scroll-to-time", _params, socket) do
    date = socket.assigns.scroll_to_date
    time = socket.assigns.scroll_to_time

    if date != "" and time != "" do
      do_scroll_to_time(socket, date, time)
    else
      {:noreply, socket |> put_flash(:info, "Please enter both date and time")}
    end
  end

  def handle_event("clear_filters", _params, socket) do
    filters = default_filters()
    logs = fetch_logs(filters)
    {cursor_top, cursor_bottom} = extract_cursors(logs)
    has_older? = cursor_top != nil and Logs.has_logs_before?(cursor_top, filter_opts(filters))

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:cursor_top, cursor_top)
     |> assign(:cursor_bottom, cursor_bottom)
     |> assign(:has_older?, has_older?)
     |> assign(:has_newer?, false)
     |> assign(:at_bottom?, true)
     |> assign(:far_from_bottom?, false)
     |> stream(:logs, logs, reset: true)}
  end

  def handle_event("load-older", _params, socket) do
    %{cursor_top: cursor, filters: filters, has_older?: has_older?} = socket.assigns

    if is_nil(cursor) or not has_older? do
      {:reply, %{}, socket}
    else
      socket = assign(socket, :loading_older?, true)
      opts = filter_opts(filters) |> Keyword.put(:limit, @per_page)
      older_logs = Logs.list_logs_before(cursor, opts)

      socket =
        if older_logs == [] do
          socket
          |> assign(:has_older?, false)
          |> assign(:loading_older?, false)
        else
          # older_logs is in desc order (newest first), so last is the oldest
          oldest = List.last(older_logs)
          new_cursor_top = {oldest.timestamp, oldest.id}
          still_has_older? = Logs.has_logs_before?(new_cursor_top, filter_opts(filters))

          # After prepending with limit, some logs are pruned from the end.
          # Recalculate cursor_bottom: query @max_logs from new_cursor_top to find the new "bottom"
          opts_for_bottom = filter_opts(filters) |> Keyword.put(:limit, @max_logs)

          new_bottom_log =
            Logs.list_logs_after(new_cursor_top, opts_for_bottom)
            |> List.last()

          new_cursor_bottom =
            if new_bottom_log do
              {new_bottom_log.timestamp, new_bottom_log.id}
            else
              # Edge case: only the prepended logs exist
              newest = List.first(older_logs)
              {newest.timestamp, newest.id}
            end

          # Don't reverse - sequential insertion at: 0 will reverse the DESC order to ASC
          socket
          |> assign(:cursor_top, new_cursor_top)
          |> assign(:cursor_bottom, new_cursor_bottom)
          |> assign(:has_older?, still_has_older?)
          |> assign(:has_newer?, true)
          |> assign(:loading_older?, false)
          |> stream(:logs, older_logs, at: 0, limit: @max_logs)
        end

      {:reply, %{}, socket}
    end
  end

  def handle_event("load-newer", _params, socket) do
    %{cursor_bottom: cursor, filters: filters, has_newer?: has_newer?} = socket.assigns

    if is_nil(cursor) or not has_newer? do
      {:reply, %{}, socket}
    else
      socket = assign(socket, :loading_newer?, true)
      opts = filter_opts(filters) |> Keyword.put(:limit, @per_page)
      newer_logs = Logs.list_logs_after(cursor, opts)

      socket =
        if newer_logs == [] do
          socket
          |> assign(:has_newer?, false)
          |> assign(:loading_newer?, false)
        else
          # newer_logs is in asc order (oldest first), so last is the newest
          newest = List.last(newer_logs)
          new_cursor_bottom = {newest.timestamp, newest.id}
          still_has_newer? = Logs.has_logs_after?(new_cursor_bottom, filter_opts(filters))

          socket
          |> assign(:cursor_bottom, new_cursor_bottom)
          |> assign(:has_newer?, still_has_newer?)
          |> assign(:has_older?, true)
          |> assign(:loading_newer?, false)
          |> stream(:logs, newer_logs, at: -1, limit: -@max_logs)
        end

      {:reply, %{}, socket}
    end
  end

  def handle_event("jump-to-latest", _params, socket) do
    filters = socket.assigns.filters
    logs = fetch_logs(filters)
    {cursor_top, cursor_bottom} = extract_cursors(logs)
    has_older? = cursor_top != nil and Logs.has_logs_before?(cursor_top, filter_opts(filters))

    {:noreply,
     socket
     |> assign(:cursor_top, cursor_top)
     |> assign(:cursor_bottom, cursor_bottom)
     |> assign(:has_older?, has_older?)
     |> assign(:has_newer?, false)
     |> assign(:at_bottom?, true)
     |> assign(:far_from_bottom?, false)
     |> stream(:logs, logs, reset: true)
     |> push_event("force-scroll-bottom", %{})}
  end

  def handle_event("scroll-away", _params, socket) do
    {:noreply, assign(socket, :at_bottom?, false)}
  end

  def handle_event("scroll-to-bottom", _params, socket) do
    {:noreply, assign(socket, :at_bottom?, true)}
  end

  def handle_event("far-from-bottom", _params, socket) do
    {:noreply, assign(socket, :far_from_bottom?, true)}
  end

  def handle_event("near-bottom", _params, socket) do
    {:noreply, assign(socket, :far_from_bottom?, false)}
  end

  def handle_event("view-in-context", %{"id" => id, "timestamp" => timestamp_str}, socket) do
    {:ok, timestamp, _} = DateTime.from_iso8601(timestamp_str)
    cursor = {timestamp, id}

    filters = default_filters()
    logs = Logs.list_logs_around(cursor, limit: @max_logs)
    {cursor_top, cursor_bottom} = extract_cursors(logs)

    has_older? = cursor_top != nil and Logs.has_logs_before?(cursor_top, filter_opts(filters))

    has_newer? =
      cursor_bottom != nil and Logs.has_logs_after?(cursor_bottom, filter_opts(filters))

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:cursor_top, cursor_top)
     |> assign(:cursor_bottom, cursor_bottom)
     |> assign(:has_older?, has_older?)
     |> assign(:has_newer?, has_newer?)
     |> assign(:at_bottom?, false)
     |> stream(:logs, logs, reset: true)
     |> push_event("scroll-to-log", %{log_id: id})}
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

      # Only insert if user is at bottom, otherwise just mark that newer logs exist
      if socket.assigns.at_bottom? do
        new_cursor_bottom = {log.timestamp, log.id}

        {:noreply,
         socket
         |> assign(:sources, sources)
         |> assign(:cursor_bottom, new_cursor_bottom)
         |> stream_insert(:logs, log, at: -1, limit: -@max_logs)}
      else
        {:noreply,
         socket
         |> assign(:sources, sources)
         |> assign(:has_newer?, true)}
      end
    else
      {:noreply, socket}
    end
  end

  defp do_scroll_to_time(socket, date, time) do
    # Parse date and time from local timezone to UTC
    # Time input with step=1 already includes seconds (HH:MM:SS)
    time_with_seconds =
      if String.contains?(time, ":") and length(String.split(time, ":")) == 3,
        do: time,
        else: "#{time}:00"

    with {:ok, naive} <- NaiveDateTime.from_iso8601("#{date}T#{time_with_seconds}"),
         local_dt <- DateTime.from_naive!(naive, "America/Los_Angeles"),
         utc_dt <- DateTime.shift_zone!(local_dt, "Etc/UTC") do
      # Create cursor and fetch logs around that time
      cursor = {utc_dt, 0}
      filters = default_filters() |> Map.put(:time_range, "all")
      logs = Logs.list_logs_around(cursor, limit: @max_logs)

      if logs == [] do
        {:noreply, socket |> put_flash(:info, "No logs found around that time")}
      else
        {cursor_top, cursor_bottom} = extract_cursors(logs)
        has_older? = cursor_top != nil and Logs.has_logs_before?(cursor_top, [])
        has_newer? = cursor_bottom != nil and Logs.has_logs_after?(cursor_bottom, [])

        # Find the first log at or after the target time
        target_log =
          Enum.find(logs, List.first(logs), fn log ->
            DateTime.compare(log.timestamp, utc_dt) != :lt
          end)

        {:noreply,
         socket
         |> assign(:filters, filters)
         |> assign(:cursor_top, cursor_top)
         |> assign(:cursor_bottom, cursor_bottom)
         |> assign(:has_older?, has_older?)
         |> assign(:has_newer?, has_newer?)
         |> assign(:at_bottom?, false)
         |> stream(:logs, logs, reset: true)
         |> push_event("scroll-to-log", %{log_id: target_log.id})}
      end
    else
      _ ->
        {:noreply, socket |> put_flash(:error, "Invalid date/time format")}
    end
  end

  defp default_filters do
    %{
      search: "",
      source: "",
      levels: ~w(debug info warning error),
      time_range: "3h"
    }
  end

  defp filters_active?(filters) do
    filters.search != "" or
      filters.source != "" or
      filters.levels != ~w(debug info warning error) or
      filters.time_range != "3h"
  end

  defp fetch_logs(filters) do
    opts = filter_opts(filters) |> Keyword.put(:limit, @max_logs)
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

  # Level abbreviations
  defp level_abbrev("debug"), do: "DEBG"
  defp level_abbrev("info"), do: "INFO"
  defp level_abbrev("warning"), do: "WARN"
  defp level_abbrev("error"), do: "EROR"
  defp level_abbrev(level), do: String.upcase(String.slice(level, 0, 4))

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
