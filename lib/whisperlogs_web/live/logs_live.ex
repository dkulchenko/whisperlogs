defmodule WhisperLogsWeb.LogsLive do
  use WhisperLogsWeb, :live_view

  alias Phoenix.LiveView.JS
  alias WhisperLogs.Logs
  alias WhisperLogs.Logs.SearchParser

  @per_page 100
  @max_logs @per_page * 5
  @flush_interval_ms 150
  @max_buffer_size 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Logs.subscribe()
    end

    sources = Logs.list_sources()

    saved_searches =
      if socket.assigns[:current_scope] && socket.assigns.current_scope.user do
        Logs.list_saved_searches(socket.assigns.current_scope.user)
      else
        []
      end

    {:ok,
     socket
     |> assign(:page_title, "Logs")
     |> assign(:sources, sources)
     |> assign(:filters, default_filters())
     |> assign(:saved_searches, saved_searches)
     |> assign(:show_save_form, false)
     |> assign(:live_tail, true)
     |> assign(:at_bottom?, true)
     |> assign(:far_from_bottom?, false)
     |> assign(:cursor_top, nil)
     |> assign(:cursor_bottom, nil)
     |> assign(:has_older?, false)
     |> assign(:has_newer?, false)
     |> assign(:loading_older?, false)
     |> assign(:loading_newer?, false)
     |> assign(:scroll_to_date, "")
     |> assign(:scroll_to_time, "")
     |> assign(:log_buffer, [])
     |> assign(:flush_timer_ref, if(connected?(socket), do: schedule_flush(), else: nil))
     |> stream(:logs, [])}
  end

  defp extract_cursors([]), do: {nil, nil}

  defp extract_cursors(logs) do
    first = List.first(logs)
    last = List.last(logs)
    {{first.timestamp, first.id}, {last.timestamp, last.id}}
  end

  defp schedule_flush do
    Process.send_after(self(), :flush_log_buffer, @flush_interval_ms)
  end

  defp flush_buffer(%{assigns: %{log_buffer: []}} = socket), do: socket

  defp flush_buffer(socket) do
    buffer = socket.assigns.log_buffer
    at_bottom? = socket.assigns.at_bottom?

    logs_to_insert = Enum.reverse(buffer)

    if at_bottom? do
      newest_log = List.last(logs_to_insert)
      new_cursor_bottom = {newest_log.timestamp, newest_log.id}

      socket
      |> assign(:log_buffer, [])
      |> assign(:cursor_bottom, new_cursor_bottom)
      |> stream(:logs, logs_to_insert, at: -1, limit: -@max_logs)
    else
      socket
      |> assign(:log_buffer, [])
      |> assign(:has_newer?, true)
    end
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
                  <span class="text-text-primary whitespace-pre-wrap">{log.message}</span>
                  <%= if log.metadata != %{} do %>
                    <span class="text-text-tertiary ml-2">
                      <span :for={{key, value} <- log.metadata} class="ml-2" phx-no-format><span class={if(key == "request_id", do: "text-purple-400", else: "text-blue-400")}>{key}</span><span class="text-text-tertiary">:</span><span class={if(key == "request_id", do: "text-purple-300", else: "text-blue-300")}>{format_metadata_value(value)}</span></span>
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
                class="hidden border-t border-border-subtle bg-bg-surface/50 px-4 py-3 ml-[72px] mr-4 mb-2 rounded-lg"
              >
                <div class="flex items-start justify-between gap-6">
                  <%!-- Timestamps --%>
                  <div class="flex items-center gap-6 text-xs">
                    <div>
                      <span class="text-text-tertiary">Logged</span>
                      <span class="ml-2 font-mono text-text-secondary">
                        {format_full_timestamp(log.timestamp)}
                      </span>
                    </div>
                    <div>
                      <span class="text-text-tertiary">Received</span>
                      <span class="ml-2 font-mono text-text-secondary">
                        {format_full_timestamp(log.inserted_at)}
                      </span>
                      <span
                        :if={timestamp_delta_ms(log.timestamp, log.inserted_at) > 100}
                        class={[
                          "ml-2 px-1.5 py-0.5 rounded text-xs font-medium",
                          timestamp_delta_class(log.timestamp, log.inserted_at)
                        ]}
                      >
                        +{format_delta(log.timestamp, log.inserted_at)}
                      </span>
                    </div>
                  </div>

                  <%!-- Actions --%>
                  <div class="flex items-center gap-2">
                    <%= if log.metadata["request_id"] do %>
                      <button
                        type="button"
                        phx-click="filter-by-request-id"
                        phx-value-request_id={log.metadata["request_id"]}
                        class="inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs font-medium bg-purple-500/10 text-purple-400 hover:bg-purple-500/20 transition-colors"
                      >
                        <.icon name="hero-funnel" class="size-3.5" /> Filter by request
                      </button>
                      <button
                        type="button"
                        phx-click={
                          JS.dispatch("whisperlogs:copy", detail: %{text: log.metadata["request_id"]})
                        }
                        class="inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs font-medium bg-bg-muted text-text-secondary hover:bg-bg-elevated hover:text-text-primary transition-colors"
                      >
                        <.icon name="hero-clipboard-document" class="size-3.5" /> Copy request ID
                      </button>
                    <% end %>
                    <button
                      type="button"
                      phx-click={JS.dispatch("whisperlogs:copy", detail: %{text: log.message})}
                      class="inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs font-medium bg-bg-muted text-text-secondary hover:bg-bg-elevated hover:text-text-primary transition-colors"
                    >
                      <.icon name="hero-clipboard-document" class="size-3.5" /> Copy message
                    </button>
                    <button
                      type="button"
                      phx-click={JS.dispatch("whisperlogs:copy", detail: %{text: log_to_json(log)})}
                      class="inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs font-medium bg-bg-muted text-text-secondary hover:bg-bg-elevated hover:text-text-primary transition-colors"
                    >
                      <.icon name="hero-code-bracket" class="size-3.5" /> Copy as JSON
                    </button>
                  </div>
                </div>
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
          class="absolute bottom-20 left-1/2 -translate-x-1/2 z-20 inline-flex items-center gap-2 px-4 py-2 bg-bg-elevated text-purple-400 text-xs font-medium rounded-full shadow-lg hover:bg-bg-surface transition-colors border border-purple-500/30"
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
            <div class="relative flex-1">
              <div class="flex items-center bg-bg-surface border border-border-default rounded-lg focus-within:border-text-tertiary transition-colors">
                <.icon
                  name="hero-magnifying-glass"
                  class="ml-3 size-4 text-text-tertiary shrink-0"
                />
                <%!-- Search input wrapper with overlay --%>
                <div class="relative flex-1 ml-2">
                  <%!-- Syntax highlight overlay --%>
                  <div
                    id="search-highlight-overlay"
                    phx-update="ignore"
                    class="absolute inset-0 pr-1 py-1.5 text-smaller font-mono whitespace-pre pointer-events-none overflow-hidden leading-normal"
                    aria-hidden="true"
                  >
                  </div>
                  <%!-- Actual input with transparent text --%>
                  <input
                    type="text"
                    name="search"
                    id="search-input"
                    value={@filters.search}
                    phx-debounce="300"
                    phx-hook=".SearchHighlight"
                    placeholder="Search... (key:value -exclude 'phrase')"
                    class="w-full bg-transparent pr-1 py-1.5 text-smaller text-transparent caret-text-primary placeholder:text-text-tertiary focus:outline-none font-mono"
                    autocomplete="off"
                    autocorrect="off"
                    autocapitalize="off"
                    spellcheck="false"
                  />
                </div>
                <%!-- Help button --%>
                <button
                  type="button"
                  phx-click={JS.toggle(to: "#search-help-popover")}
                  class="p-1.5 rounded hover:bg-bg-muted transition-colors shrink-0"
                  aria-label="Search syntax help"
                >
                  <.icon
                    name="hero-question-mark-circle"
                    class="size-4 text-text-tertiary hover:text-text-secondary"
                  />
                </button>
                <select
                  name="time_range"
                  class="bg-transparent border-l border-border-default px-2 py-1.5 text-smaller text-text-secondary focus:outline-none cursor-pointer shrink-0"
                >
                  <option value="3h" selected={@filters.time_range == "3h"}>Last 3h</option>
                  <option value="12h" selected={@filters.time_range == "12h"}>Last 12h</option>
                  <option value="24h" selected={@filters.time_range == "24h"}>Last 24h</option>
                  <option value="7d" selected={@filters.time_range == "7d"}>Last 7d</option>
                  <option value="30d" selected={@filters.time_range == "30d"}>Last 30d</option>
                  <option value="all" selected={@filters.time_range == "all"}>All time</option>
                </select>
              </div>

              <%!-- Search help popover --%>
              <div
                id="search-help-popover"
                class="hidden absolute bottom-full left-0 mb-2 w-80 p-4 bg-bg-elevated border border-border-default rounded-lg shadow-xl z-50"
                phx-click-away={JS.hide(to: "#search-help-popover")}
              >
                <div class="flex items-center justify-between mb-3">
                  <h3 class="text-sm font-semibold text-text-primary">Search Syntax</h3>
                  <button
                    type="button"
                    phx-click={JS.hide(to: "#search-help-popover")}
                    class="p-1 rounded hover:bg-bg-muted transition-colors"
                  >
                    <.icon name="hero-x-mark" class="size-4 text-text-tertiary" />
                  </button>
                </div>

                <div class="space-y-3 text-xs">
                  <div>
                    <div class="flex items-center gap-2 mb-1">
                      <.icon name="hero-magnifying-glass" class="size-3.5 text-blue-400" />
                      <span class="font-medium text-text-primary">Basic Search</span>
                    </div>
                    <p class="text-text-secondary ml-5">
                      Search in messages and all metadata values
                    </p>
                    <code class="block mt-1 ml-5 px-2 py-1 bg-bg-surface rounded text-text-tertiary font-mono">
                      connection error
                    </code>
                  </div>

                  <div>
                    <div class="flex items-center gap-2 mb-1">
                      <.icon name="hero-key" class="size-3.5 text-purple-400" />
                      <span class="font-medium text-text-primary">Metadata Filter</span>
                    </div>
                    <p class="text-text-secondary ml-5">
                      Filter by specific metadata fields
                    </p>
                    <code class="block mt-1 ml-5 px-2 py-1 bg-bg-surface rounded font-mono">
                      <span class="text-purple-400">user_id</span><span class="text-text-tertiary">:</span><span class="text-purple-300">123</span>
                    </code>
                  </div>

                  <div>
                    <div class="flex items-center gap-2 mb-1">
                      <.icon name="hero-calculator" class="size-3.5 text-cyan-400" />
                      <span class="font-medium text-text-primary">Numeric Compare</span>
                    </div>
                    <p class="text-text-secondary ml-5">
                      Use <span class="text-cyan-400">&gt;</span>
                      <span class="text-cyan-400">&gt;=</span>
                      <span class="text-cyan-400">&lt;</span>
                      <span class="text-cyan-400">&lt;=</span> for numbers
                    </p>
                    <code class="block mt-1 ml-5 px-2 py-1 bg-bg-surface rounded font-mono">
                      <span class="text-purple-400">duration_ms</span><span class="text-text-tertiary">:</span><span class="text-cyan-400">&gt;</span><span class="text-purple-300">100</span>
                    </code>
                  </div>

                  <div>
                    <div class="flex items-center gap-2 mb-1">
                      <.icon name="hero-funnel" class="size-3.5 text-cyan-400" />
                      <span class="font-medium text-text-primary">Special Filters</span>
                    </div>
                    <p class="text-text-secondary ml-5">
                      Filter by level, timestamp, or source
                    </p>
                    <div class="mt-1 ml-5 space-y-1">
                      <code class="block px-2 py-1 bg-bg-surface rounded font-mono">
                        <span class="text-cyan-400">level</span><span class="text-text-tertiary">:</span><span class="text-cyan-300">error</span>
                      </code>
                      <code class="block px-2 py-1 bg-bg-surface rounded font-mono">
                        <span class="text-cyan-400">timestamp</span><span class="text-text-tertiary">:</span><span class="text-cyan-400">&gt;</span><span class="text-cyan-300">-1h</span>
                      </code>
                      <code class="block px-2 py-1 bg-bg-surface rounded font-mono">
                        <span class="text-cyan-400">source</span><span class="text-text-tertiary">:</span><span class="text-cyan-300">prod</span>
                      </code>
                    </div>
                    <p class="text-text-tertiary ml-5 mt-1 text-[10px]">
                      Timestamps: today, yesterday, -1h, -7d, 2025-08-12
                    </p>
                    <p class="text-text-tertiary ml-5 text-[10px]">
                      Levels: debug/dbg, info/inf, warning/warn, error/err
                    </p>
                  </div>

                  <div>
                    <div class="flex items-center gap-2 mb-1">
                      <.icon name="hero-minus-circle" class="size-3.5 text-red-400" />
                      <span class="font-medium text-text-primary">Exclude Terms</span>
                    </div>
                    <p class="text-text-secondary ml-5">
                      Prefix with <span class="text-red-400">-</span> to exclude
                    </p>
                    <code class="block mt-1 ml-5 px-2 py-1 bg-bg-surface rounded font-mono">
                      error <span class="text-red-400">-oban</span>
                      <span class="text-red-400">-healthcheck</span>
                    </code>
                  </div>

                  <div>
                    <div class="flex items-center gap-2 mb-1">
                      <.icon
                        name="hero-chat-bubble-bottom-center-text"
                        class="size-3.5 text-amber-400"
                      />
                      <span class="font-medium text-text-primary">Exact Phrase</span>
                    </div>
                    <p class="text-text-secondary ml-5">
                      Use quotes for exact phrase matching
                    </p>
                    <code class="block mt-1 ml-5 px-2 py-1 bg-bg-surface rounded font-mono">
                      <span class="text-amber-400">"connection timeout"</span>
                    </code>
                  </div>

                  <div>
                    <div class="flex items-center gap-2 mb-1">
                      <.icon name="hero-code-bracket" class="size-3.5 text-green-400" />
                      <span class="font-medium text-text-primary">Regex Pattern</span>
                    </div>
                    <p class="text-text-secondary ml-5">
                      Use /pattern/ for regex, prefix with - to exclude
                    </p>
                    <code class="block mt-1 ml-5 px-2 py-1 bg-bg-surface rounded font-mono">
                      <span class="text-red-400">-</span><span class="text-green-400">/easypost|healthcheck/</span>
                    </code>
                  </div>

                  <div class="pt-2 border-t border-border-subtle">
                    <div class="flex items-center gap-2 mb-1">
                      <.icon name="hero-sparkles" class="size-3.5 text-accent-purple" />
                      <span class="font-medium text-text-primary">Combined Example</span>
                    </div>
                    <code class="block mt-1 ml-5 px-2 py-1 bg-bg-surface rounded font-mono text-xs">
                      <span class="text-purple-400">user_id</span>:<span class="text-purple-300">42</span>
                      <span class="text-amber-400">"failed"</span>
                      <span class="text-red-400">-retry</span>
                    </code>
                  </div>
                </div>
              </div>
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
                    class="px-3 py-1.5 bg-purple-500/10 text-purple-400 rounded-lg text-smaller font-medium hover:bg-purple-500/20 transition-colors border border-purple-500/30"
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
                @live_tail &&
                  "bg-purple-500/10 border-purple-500/30 text-purple-400 hover:bg-purple-500/20",
                !@live_tail &&
                  "bg-bg-surface border-border-default text-text-secondary hover:text-text-primary hover:border-border-subtle"
              ]}
            >
              <%= if @live_tail do %>
                <span class="relative flex size-2">
                  <span class="live-wave absolute inset-0 rounded-full bg-purple-400"></span>
                  <span class="live-wave-delayed absolute inset-0 rounded-full bg-purple-400"></span>
                  <span class="relative inline-flex rounded-full size-2 bg-purple-400"></span>
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

            <%!-- Saved Searches --%>
            <div class="relative">
              <button
                type="button"
                phx-click={JS.toggle(to: "#saved-searches-popover")}
                class={[
                  "inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-smaller font-medium transition-all border",
                  "bg-bg-surface border-border-default text-text-secondary hover:text-text-primary hover:border-border-subtle"
                ]}
                title="Saved searches"
              >
                <.icon name="hero-bookmark" class="size-3.5" />
                <span :if={@saved_searches != []} class="text-xs text-text-tertiary">
                  {length(@saved_searches)}
                </span>
              </button>

              <div
                id="saved-searches-popover"
                class="hidden absolute bottom-full right-0 mb-2 w-72 bg-bg-elevated border border-border-default rounded-lg shadow-xl z-50"
                phx-click-away={JS.hide(to: "#saved-searches-popover")}
              >
                <div class="p-3">
                  <div class="flex items-center justify-between mb-2">
                    <h3 class="text-sm font-semibold text-text-primary">Saved Searches</h3>
                    <button
                      type="button"
                      phx-click={JS.hide(to: "#saved-searches-popover")}
                      class="p-1 rounded hover:bg-bg-muted transition-colors"
                    >
                      <.icon name="hero-x-mark" class="size-4 text-text-tertiary" />
                    </button>
                  </div>

                  <%= if @saved_searches == [] do %>
                    <p class="text-xs text-text-tertiary py-3 text-center">
                      No saved searches yet
                    </p>
                  <% else %>
                    <div class="space-y-1 max-h-48 overflow-y-auto">
                      <div
                        :for={saved <- @saved_searches}
                        class="group flex items-center gap-2 px-2 py-1.5 rounded-lg hover:bg-bg-surface transition-colors"
                      >
                        <button
                          type="button"
                          phx-click={
                            JS.push("load-saved-search", value: %{id: saved.id})
                            |> JS.hide(to: "#saved-searches-popover")
                          }
                          class="flex-1 text-left text-sm text-text-primary truncate"
                          title={saved_search_summary(saved)}
                        >
                          {saved.name}
                        </button>
                        <button
                          type="button"
                          phx-click="delete-saved-search"
                          phx-value-id={saved.id}
                          data-confirm="Delete this saved search?"
                          class="p-1 rounded opacity-0 group-hover:opacity-100 hover:bg-red-500/10 transition-all"
                        >
                          <.icon
                            name="hero-trash"
                            class="size-3.5 text-text-tertiary hover:text-red-400"
                          />
                        </button>
                      </div>
                    </div>
                  <% end %>

                  <div class="mt-2 pt-2 border-t border-border-subtle">
                    <%= if @show_save_form do %>
                      <div class="flex items-center gap-2">
                        <input
                          type="text"
                          name="name"
                          form="save-search-form"
                          placeholder="Search name..."
                          class="flex-1 bg-bg-surface border border-border-default rounded-lg px-2 py-1.5 text-smaller text-text-primary focus:outline-none focus:border-text-tertiary placeholder:text-text-tertiary"
                          autofocus
                          required
                        />
                        <button
                          type="submit"
                          form="save-search-form"
                          class="px-2 py-1.5 bg-purple-500/10 text-purple-400 rounded-lg text-smaller font-medium hover:bg-purple-500/20 transition-colors border border-purple-500/30"
                        >
                          Save
                        </button>
                        <button
                          type="button"
                          phx-click="toggle-save-form"
                          class="p-1.5 rounded hover:bg-bg-muted transition-colors"
                        >
                          <.icon name="hero-x-mark" class="size-3.5 text-text-tertiary" />
                        </button>
                      </div>
                    <% else %>
                      <button
                        type="button"
                        phx-click="toggle-save-form"
                        class="w-full flex items-center justify-center gap-1.5 px-2 py-1.5 rounded-lg text-smaller font-medium text-purple-400 hover:bg-purple-500/10 transition-colors"
                      >
                        <.icon name="hero-plus" class="size-3.5" /> Save current filters
                      </button>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </form>
        <form id="save-search-form" phx-submit="save-search" class="hidden"></form>
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

    <script :type={Phoenix.LiveView.ColocatedHook} name=".SearchHighlight">
      // Token patterns matching the Elixir parser
      // Order matters - more specific patterns first
      const TOKEN_PATTERNS = [
        { type: 'exclude_metadata_quoted', regex: /-[\w.-]+:"[^"]*"/ },
        { type: 'metadata_quoted', regex: /[\w.-]+:"[^"]*"/ },
        { type: 'exclude_phrase', regex: /-"[^"]*"/ },
        { type: 'exclude_regex', regex: /-\/(?:[^\/\\]|\\.)+\// },
        { type: 'phrase', regex: /"[^"]*"/ },
        { type: 'regex', regex: /\/(?:[^\/\\]|\\.)+\// },
        { type: 'exclude_metadata_op', regex: /-[\w.-]+:(?:>=|<=|>|<)[\w.-]+/ },
        { type: 'metadata_op', regex: /[\w.-]+:(?:>=|<=|>|<)[\w.-]+/ },
        { type: 'exclude_metadata', regex: /-[\w.-]+:[\w.-]+/ },
        { type: 'metadata', regex: /[\w.-]+:[\w.-]+/ },
        { type: 'exclude', regex: /-[\w.-]+/ },
        { type: 'term', regex: /[\w.-]+/ }
      ]

      // Pseudo-keys filter on schema fields, not metadata JSONB
      const PSEUDO_KEYS = ['level', 'timestamp', 'source']

      function isPseudoKey(key) {
        return PSEUDO_KEYS.includes(key.toLowerCase())
      }

      function highlightToken(token, type) {
        const escaped = token.replace(/</g, '&lt;').replace(/>/g, '&gt;')

        switch (type) {
          case 'exclude_phrase':
            const epPhrase = token.slice(1) // remove leading -
            return `<span class="text-red-400">-</span><span class="text-amber-400">${epPhrase.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</span>`

          case 'phrase':
            return `<span class="text-amber-400">${escaped}</span>`

          case 'regex':
            return `<span class="text-green-400">${escaped}</span>`

          case 'exclude_regex':
            const erBody = token.slice(1) // remove leading -
            return `<span class="text-red-400">-</span><span class="text-green-400">${erBody.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</span>`

          case 'metadata':
          case 'metadata_quoted':
            const [key, ...valueParts] = token.split(':')
            const value = valueParts.join(':')
            // Use cyan for pseudo-keys, purple for regular metadata
            const keyColor = isPseudoKey(key) ? 'text-cyan-400' : 'text-purple-400'
            const valColor = isPseudoKey(key) ? 'text-cyan-300' : 'text-purple-300'
            return `<span class="${keyColor}">${key.replace(/</g, '&lt;')}</span><span class="text-text-tertiary">:</span><span class="${valColor}">${value.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</span>`

          case 'metadata_op':
            const opMatch = token.match(/^([\w.-]+):(>=|<=|>|<)([\w.-]+)$/)
            if (opMatch) {
              const [, mKey, mOp, mVal] = opMatch
              const mKeyColor = isPseudoKey(mKey) ? 'text-cyan-400' : 'text-purple-400'
              const mValColor = isPseudoKey(mKey) ? 'text-cyan-300' : 'text-purple-300'
              return `<span class="${mKeyColor}">${mKey}</span><span class="text-text-tertiary">:</span><span class="text-cyan-400">${mOp}</span><span class="${mValColor}">${mVal}</span>`
            }
            return escaped

          case 'exclude':
            return `<span class="text-red-400">${escaped}</span>`

          case 'exclude_metadata':
          case 'exclude_metadata_quoted':
            const content = token.slice(1) // remove leading -
            const [eKey, ...eValueParts] = content.split(':')
            const eValue = eValueParts.join(':')
            // Use orange for excluded pseudo-keys, red for regular excluded metadata
            const eKeyColor = isPseudoKey(eKey) ? 'text-orange-400' : 'text-red-300'
            const eValColor = isPseudoKey(eKey) ? 'text-orange-300' : 'text-red-300'
            return `<span class="text-red-400">-</span><span class="${eKeyColor}">${eKey.replace(/</g, '&lt;')}</span><span class="text-text-tertiary">:</span><span class="${eValColor}">${eValue.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</span>`

          case 'exclude_metadata_op':
            const eOpMatch = token.match(/^-([\w.-]+):(>=|<=|>|<)([\w.-]+)$/)
            if (eOpMatch) {
              const [, emKey, emOp, emVal] = eOpMatch
              const emKeyColor = isPseudoKey(emKey) ? 'text-orange-400' : 'text-red-300'
              const emValColor = isPseudoKey(emKey) ? 'text-orange-300' : 'text-red-300'
              return `<span class="text-red-400">-</span><span class="${emKeyColor}">${emKey}</span><span class="text-text-tertiary">:</span><span class="text-cyan-400">${emOp}</span><span class="${emValColor}">${emVal}</span>`
            }
            return escaped

          case 'term':
          default:
            return `<span class="text-text-primary">${escaped}</span>`
        }
      }

      function escapeHtml(text) {
        return text
          .replace(/&/g, '&amp;')
          .replace(/</g, '&lt;')
          .replace(/>/g, '&gt;')
      }

      function parseAndHighlight(text) {
        if (!text) return ''

        let result = ''
        let lastIndex = 0

        // Build a combined regex from all patterns
        const combinedPattern = new RegExp(
          TOKEN_PATTERNS.map(p => `(${p.regex.source})`).join('|'),
          'g'
        )

        let match
        while ((match = combinedPattern.exec(text)) !== null) {
          // Add any whitespace/text before this match (preserve spaces)
          if (match.index > lastIndex) {
            const between = text.slice(lastIndex, match.index)
            result += escapeHtml(between)
          }

          // Find which pattern matched
          const matchedText = match[0]
          let matchType = 'term'
          for (let i = 0; i < TOKEN_PATTERNS.length; i++) {
            if (match[i + 1] !== undefined) {
              matchType = TOKEN_PATTERNS[i].type
              break
            }
          }

          result += highlightToken(matchedText, matchType)
          lastIndex = match.index + matchedText.length
        }

        // Add any remaining text
        if (lastIndex < text.length) {
          result += escapeHtml(text.slice(lastIndex))
        }

        return result
      }

      export default {
        mounted() {
          this.overlay = document.getElementById('search-highlight-overlay')
          this.updateHighlight()
          this.syncScroll()

          this.el.addEventListener('input', () => this.updateHighlight())
          this.el.addEventListener('focus', () => this.updateHighlight())
          this.el.addEventListener('scroll', () => this.syncScroll())
          this.el.addEventListener('keyup', () => this.syncScroll())
          this.el.addEventListener('click', () => this.syncScroll())
        },

        updated() {
          this.updateHighlight()
          this.syncScroll()
        },

        syncScroll() {
          if (this.overlay) {
            this.overlay.scrollLeft = this.el.scrollLeft
          }
        },

        updateHighlight() {
          if (this.overlay) {
            const value = this.el.value || ''
            if (value === '') {
              this.overlay.innerHTML = ''
            } else {
              this.overlay.innerHTML = parseAndHighlight(value)
            }
            this.syncScroll()
          }
        }
      }
    </script>
    """
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = params_to_filters(params)
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
     |> assign(:log_buffer, [])
     |> stream(:logs, logs, reset: true)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters = %{
      search: params["search"] || "",
      source: params["source"] || "",
      levels: params["levels"] || [],
      time_range: params["time_range"] || socket.assigns.filters.time_range
    }

    {:noreply, push_patch(socket, to: ~p"/?#{filters_to_params(filters)}")}
  end

  def handle_event("toggle_live_tail", _params, socket) do
    new_live_tail = !socket.assigns.live_tail

    socket =
      if new_live_tail do
        assign(socket, :flush_timer_ref, schedule_flush())
      else
        if socket.assigns.flush_timer_ref do
          Process.cancel_timer(socket.assigns.flush_timer_ref)
        end

        socket
        |> assign(:flush_timer_ref, nil)
        |> assign(:log_buffer, [])
      end

    {:noreply, assign(socket, :live_tail, new_live_tail)}
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
    {:noreply, push_patch(socket, to: ~p"/")}
  end

  def handle_event("save-search", %{"name" => name}, socket) do
    filters = socket.assigns.filters
    user = socket.assigns.current_scope.user

    attrs = %{
      name: String.trim(name),
      search: filters.search,
      source: filters.source,
      levels: filters.levels,
      time_range: filters.time_range
    }

    case Logs.create_saved_search(user, attrs) do
      {:ok, _saved_search} ->
        saved_searches = Logs.list_saved_searches(user)

        {:noreply,
         socket
         |> assign(:saved_searches, saved_searches)
         |> assign(:show_save_form, false)
         |> put_flash(:info, "Search saved")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save search. Name may already be taken.")}
    end
  end

  def handle_event("load-saved-search", %{"id" => id}, socket) do
    case Logs.get_saved_search(socket.assigns.current_scope.user, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Saved search not found")}

      saved_search ->
        filters = %{
          search: saved_search.search,
          source: saved_search.source,
          levels: saved_search.levels,
          time_range: saved_search.time_range
        }

        {:noreply, push_patch(socket, to: ~p"/?#{filters_to_params(filters)}")}
    end
  end

  def handle_event("delete-saved-search", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Logs.get_saved_search(user, id) do
      nil ->
        {:noreply, socket}

      saved_search ->
        {:ok, _} = Logs.delete_saved_search(saved_search)
        saved_searches = Logs.list_saved_searches(user)

        {:noreply,
         socket
         |> assign(:saved_searches, saved_searches)
         |> put_flash(:info, "Saved search deleted")}
    end
  end

  def handle_event("toggle-save-form", _params, socket) do
    {:noreply, assign(socket, :show_save_form, !socket.assigns.show_save_form)}
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
     |> assign(:log_buffer, [])
     |> stream(:logs, logs, reset: true)
     |> push_event("force-scroll-bottom", %{})}
  end

  def handle_event("scroll-away", _params, socket) do
    socket =
      if socket.assigns.log_buffer != [] do
        socket
        |> assign(:log_buffer, [])
        |> assign(:has_newer?, true)
      else
        socket
      end

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

  def handle_event("filter-by-request-id", %{"request_id" => request_id}, socket) do
    filters = %{socket.assigns.filters | search: "request_id:#{request_id}"}
    {:noreply, push_patch(socket, to: ~p"/?#{filters_to_params(filters)}")}
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
     |> assign(:log_buffer, [])
     |> stream(:logs, logs, reset: true)
     |> push_event("scroll-to-log", %{log_id: id})}
  end

  @impl true
  def handle_info({:new_log, log}, socket) do
    if socket.assigns.live_tail and log_matches_filters?(log, socket.assigns.filters) do
      buffer = [log | socket.assigns.log_buffer]

      sources =
        if log.source in socket.assigns.sources do
          socket.assigns.sources
        else
          [log.source | socket.assigns.sources] |> Enum.sort()
        end

      socket =
        socket
        |> assign(:sources, sources)
        |> assign(:log_buffer, buffer)

      # Force flush if buffer too large (back-pressure)
      if length(buffer) >= @max_buffer_size do
        {:noreply, flush_buffer(socket)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(:flush_log_buffer, socket) do
    socket =
      if socket.assigns.live_tail do
        socket
        |> assign(:flush_timer_ref, schedule_flush())
        |> flush_buffer()
      else
        assign(socket, :flush_timer_ref, nil)
      end

    {:noreply, socket}
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

  defp params_to_filters(params) do
    defaults = default_filters()

    levels =
      case params["levels"] do
        nil -> defaults.levels
        "" -> []
        levels_str -> String.split(levels_str, ",")
      end

    %{
      search: params["q"] || defaults.search,
      source: params["source"] || defaults.source,
      levels: levels,
      time_range: params["t"] || defaults.time_range
    }
  end

  defp filters_to_params(filters) do
    defaults = default_filters()
    params = %{}

    params =
      if filters.search != defaults.search,
        do: Map.put(params, "q", filters.search),
        else: params

    params =
      if filters.time_range != defaults.time_range,
        do: Map.put(params, "t", filters.time_range),
        else: params

    params =
      if filters.source != defaults.source,
        do: Map.put(params, "source", filters.source),
        else: params

    if Enum.sort(filters.levels) != Enum.sort(defaults.levels),
      do: Map.put(params, "levels", Enum.join(filters.levels, ",")),
      else: params
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
      case SearchParser.parse(filters.search) do
        {:ok, []} -> true
        {:ok, tokens} -> Enum.all?(tokens, &log_matches_token?(log, &1))
      end

    level_match and source_match and search_match
  end

  defp log_matches_token?(log, {:term, term}) do
    term_lower = String.downcase(term)
    message_match = String.contains?(String.downcase(log.message), term_lower)

    metadata_match =
      Enum.any?(log.metadata, fn {_k, v} ->
        String.contains?(String.downcase(stringify_value(v)), term_lower)
      end)

    message_match or metadata_match
  end

  defp log_matches_token?(log, {:phrase, phrase}) do
    log_matches_token?(log, {:term, phrase})
  end

  defp log_matches_token?(log, {:exclude_phrase, phrase}) do
    not log_matches_token?(log, {:term, phrase})
  end

  defp log_matches_token?(log, {:regex, pattern}) do
    case Regex.compile(pattern, "i") do
      {:ok, re} ->
        Regex.match?(re, log.message) or
          Enum.any?(log.metadata, fn {_k, v} -> Regex.match?(re, stringify_value(v)) end)

      {:error, _} ->
        false
    end
  end

  defp log_matches_token?(log, {:exclude_regex, pattern}) do
    not log_matches_token?(log, {:regex, pattern})
  end

  defp log_matches_token?(log, {:exclude, term}) do
    not log_matches_token?(log, {:term, term})
  end

  defp log_matches_token?(log, {:metadata, key, :eq, value}) do
    case Map.get(log.metadata, key) do
      nil -> false
      v -> String.contains?(String.downcase(stringify_value(v)), String.downcase(value))
    end
  end

  defp log_matches_token?(log, {:metadata, key, operator, value}) do
    case Map.get(log.metadata, key) do
      nil -> false
      v -> compare_numeric(v, operator, value)
    end
  end

  defp log_matches_token?(log, {:exclude_metadata, key, :eq, value}) do
    case Map.get(log.metadata, key) do
      nil -> true
      v -> not String.contains?(String.downcase(stringify_value(v)), String.downcase(value))
    end
  end

  defp log_matches_token?(log, {:exclude_metadata, key, operator, value}) do
    case Map.get(log.metadata, key) do
      nil -> true
      v -> not compare_numeric(v, operator, value)
    end
  end

  # Level filter - exact match on level field
  defp log_matches_token?(log, {:level_filter, level}) do
    log.level == level
  end

  defp log_matches_token?(log, {:exclude_level_filter, level}) do
    log.level != level
  end

  # Timestamp filter - comparison on timestamp field
  defp log_matches_token?(log, {:timestamp_filter, :eq, datetime}) do
    # Match within the same second
    diff = DateTime.diff(log.timestamp, datetime, :second)
    diff >= 0 and diff < 1
  end

  defp log_matches_token?(log, {:timestamp_filter, :gt, datetime}) do
    DateTime.compare(log.timestamp, datetime) == :gt
  end

  defp log_matches_token?(log, {:timestamp_filter, :gte, datetime}) do
    DateTime.compare(log.timestamp, datetime) in [:gt, :eq]
  end

  defp log_matches_token?(log, {:timestamp_filter, :lt, datetime}) do
    DateTime.compare(log.timestamp, datetime) == :lt
  end

  defp log_matches_token?(log, {:timestamp_filter, :lte, datetime}) do
    DateTime.compare(log.timestamp, datetime) in [:lt, :eq]
  end

  # Exclude timestamp filter - negate the condition
  defp log_matches_token?(log, {:exclude_timestamp_filter, operator, datetime}) do
    not log_matches_token?(log, {:timestamp_filter, operator, datetime})
  end

  # Source filter - case-insensitive contains
  defp log_matches_token?(log, {:source_filter, pattern}) do
    String.contains?(String.downcase(log.source || ""), String.downcase(pattern))
  end

  defp log_matches_token?(log, {:exclude_source_filter, pattern}) do
    not String.contains?(String.downcase(log.source || ""), String.downcase(pattern))
  end

  defp compare_numeric(metadata_value, operator, search_value) do
    with {meta_num, ""} <- Float.parse(to_string(metadata_value)),
         {search_num, ""} <- Float.parse(search_value) do
      case operator do
        :gt -> meta_num > search_num
        :gte -> meta_num >= search_num
        :lt -> meta_num < search_num
        :lte -> meta_num <= search_num
      end
    else
      _ -> false
    end
  end

  defp saved_search_summary(saved) do
    parts = []
    parts = if saved.search != "", do: ["q: #{saved.search}" | parts], else: parts
    parts = if saved.source != "", do: ["source: #{saved.source}" | parts], else: parts
    parts = if saved.time_range != "3h", do: ["time: #{saved.time_range}" | parts], else: parts

    if Enum.sort(saved.levels) != Enum.sort(~w(debug info warning error)) do
      parts = ["levels: #{Enum.join(saved.levels, ", ")}" | parts]
      Enum.reverse(parts) |> Enum.join(" | ")
    else
      Enum.reverse(parts) |> Enum.join(" | ")
    end
  end

  defp level_selected?(levels, level), do: level in levels

  # Filter button styling (when selected)
  defp level_filter_bg("debug"), do: "bg-bg-muted border-text-tertiary text-text-secondary"
  defp level_filter_bg("info"), do: "bg-blue-400/20 border-blue-400/50 text-blue-300"
  defp level_filter_bg("warning"), do: "bg-amber-400/20 border-amber-400/50 text-amber-300"
  defp level_filter_bg("error"), do: "bg-red-400/20 border-red-400/50 text-red-300"
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

    Calendar.strftime(local_dt, "%m/%d %I:%M:%S.") <>
      format_milliseconds(local_dt) <> Calendar.strftime(local_dt, " %P")
  end

  defp format_full_timestamp(dt) do
    local_dt = DateTime.shift_zone!(dt, "America/Los_Angeles")
    Calendar.strftime(local_dt, "%Y-%m-%d %H:%M:%S.") <> format_milliseconds(local_dt)
  end

  defp format_milliseconds(%DateTime{microsecond: {us, _}}) do
    us |> div(1000) |> Integer.to_string() |> String.pad_leading(3, "0")
  end

  defp timestamp_delta_ms(logged, received) do
    DateTime.diff(received, logged, :millisecond)
  end

  defp timestamp_delta_class(logged, received) do
    delta_ms = timestamp_delta_ms(logged, received)

    cond do
      delta_ms > 60_000 -> "bg-red-500/20 text-red-400"
      delta_ms > 5_000 -> "bg-amber-500/20 text-amber-400"
      delta_ms > 100 -> "bg-blue-500/20 text-blue-400"
      true -> ""
    end
  end

  defp format_delta(logged, received) do
    delta_ms = timestamp_delta_ms(logged, received)

    cond do
      delta_ms >= 60_000 -> "#{Float.round(delta_ms / 60_000, 1)}m"
      delta_ms >= 1_000 -> "#{Float.round(delta_ms / 1_000, 1)}s"
      true -> "#{delta_ms}ms"
    end
  end

  defp log_to_json(log) do
    %{
      timestamp: DateTime.to_iso8601(log.timestamp),
      received_at: DateTime.to_iso8601(log.inserted_at),
      level: log.level,
      message: log.message,
      source: log.source,
      metadata: log.metadata
    }
    |> Jason.encode!(pretty: true)
  end

  # Safe stringification for metadata values that may be maps, lists, etc.
  # Used by live filtering to avoid String.Chars crash on non-primitive values.
  defp stringify_value(v) when is_binary(v), do: v
  defp stringify_value(v) when is_atom(v) or is_number(v), do: to_string(v)
  defp stringify_value(v), do: Jason.encode!(v)

  defp format_metadata_value(value) when is_binary(value), do: value
  defp format_metadata_value(value) when is_number(value), do: to_string(value)
  defp format_metadata_value(value) when is_boolean(value), do: to_string(value)
  defp format_metadata_value(value) when is_nil(value), do: "null"
  defp format_metadata_value(value), do: Jason.encode!(value)
end
