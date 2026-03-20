defmodule WhisperLogsWeb.MetricsLive do
  use WhisperLogsWeb, :live_view

  require Logger

  alias WhisperLogs.Logs
  alias WhisperLogs.Retention

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Metrics")
      |> assign(:loading, true)
      |> assign(:total_count, 0)
      |> assign(:total_bytes, 0)
      |> assign(:retention_days, Retention.retention_days())
      |> assign(:hourly_data, [])
      |> assign(:daily_data, [])
      |> assign(:monthly_data, [])
      |> assign(:projected_30d_count, 0)
      |> assign(:projected_30d_bytes, 0)
      |> assign(:time_range, "daily")

    socket =
      if connected?(socket) do
        start_async(socket, :load_metrics, fn ->
          load_metrics_data()
        end)
      else
        socket
      end

    {:ok, socket}
  end

  # Run only 2 DB queries instead of 6:
  # 1) daily volume for last 12 months (the expensive length() scan, done once)
  # 2) hourly volume for last 48h (small dataset, fast)
  # Everything else is derived in Elixir from these two results.
  defp load_metrics_data do
    hourly_data = Logs.volume_by_hour(48)
    daily_data = Logs.volume_by_day(365)

    # Monthly: roll up daily data in Elixir
    monthly_data =
      daily_data
      |> Enum.group_by(fn {dt, _, _} -> {dt.year, dt.month} end)
      |> Enum.map(fn {{year, month}, days} ->
        count = Enum.sum(Enum.map(days, fn {_, c, _} -> c end))
        bytes = Enum.sum(Enum.map(days, fn {_, _, b} -> b || 0 end))
        {:ok, dt} = DateTime.new(Date.new!(year, month, 1), ~T[00:00:00], "Etc/UTC")
        {dt, count, bytes}
      end)
      |> Enum.sort_by(fn {dt, _, _} -> DateTime.to_unix(dt) end)

    # Totals: sum all daily data
    total_count = Enum.sum(Enum.map(daily_data, fn {_, c, _} -> c end))
    total_bytes = Enum.sum(Enum.map(daily_data, fn {_, _, b} -> b || 0 end))

    # Projection: use last 48h of hourly data for velocity estimate
    {projected_30d_count, projected_30d_bytes} =
      calculate_30d_projection(hourly_data)

    %{
      total_count: total_count,
      total_bytes: total_bytes,
      hourly_data: hourly_data,
      daily_data:
        Enum.filter(daily_data, fn {dt, _, _} ->
          DateTime.diff(DateTime.utc_now(), dt, :day) <= 30
        end),
      monthly_data: monthly_data,
      projected_30d_count: projected_30d_count,
      projected_30d_bytes: projected_30d_bytes
    }
  end

  defp calculate_30d_projection([]), do: {0, 0}

  defp calculate_30d_projection(hourly_data) do
    hours = length(hourly_data) |> max(1)
    total_count = Enum.sum(Enum.map(hourly_data, fn {_, c, _} -> c end))
    total_bytes = Enum.sum(Enum.map(hourly_data, fn {_, _, b} -> b || 0 end))

    hourly_avg_count = total_count / hours
    hourly_avg_bytes = total_bytes / hours

    {round(hourly_avg_count * 24 * 30), round(hourly_avg_bytes * 24 * 30)}
  end

  @impl true
  def handle_async(:load_metrics, {:ok, metrics}, socket) do
    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:total_count, metrics.total_count)
     |> assign(:total_bytes, metrics.total_bytes)
     |> assign(:hourly_data, metrics.hourly_data)
     |> assign(:daily_data, metrics.daily_data)
     |> assign(:monthly_data, metrics.monthly_data)
     |> assign(:projected_30d_count, metrics.projected_30d_count)
     |> assign(:projected_30d_bytes, metrics.projected_30d_bytes)
     |> push_event("chart-data", %{data: chart_data(socket.assigns.time_range, metrics)})}
  end

  @impl true
  def handle_async(:load_metrics, {:exit, reason}, socket) do
    Logger.error("Failed to load metrics: #{inspect(reason)}")
    {:noreply, assign(socket, :loading, false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex-1 overflow-y-auto">
        <div class="max-w-6xl mx-auto px-6 py-8">
          <.header>
            Metrics
            <:subtitle>
              Log volume statistics and projections
            </:subtitle>
          </.header>

          <%= if @loading do %>
            <div class="mt-16 flex flex-col items-center justify-center py-20">
              <.icon name="hero-arrow-path" class="size-8 animate-spin text-accent-purple mb-4" />
              <p class="text-text-secondary">Loading metrics...</p>
            </div>
          <% else %>
            <%!-- Summary Cards --%>
            <div class="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
              <.stat_card
                title="Total Logs Stored"
                value={format_count(@total_count)}
                subtitle={"Retention: #{@retention_days} days"}
                icon="hero-document-text"
              />
              <.stat_card
                title="Total Volume"
                value={format_bytes(@total_bytes)}
                subtitle={format_count(@total_count) <> " entries"}
                icon="hero-server-stack"
              />
              <.stat_card
                title="30-Day Projection"
                value={"~" <> format_bytes(@projected_30d_bytes)}
                subtitle={format_count(@projected_30d_count) <> " logs"}
                icon="hero-chart-bar"
              />
              <.stat_card
                title="Retention Period"
                value={"#{@retention_days} days"}
                subtitle="Configurable via env"
                icon="hero-clock"
              />
            </div>

            <%!-- Time Range Selector --%>
            <div class="mt-8 flex items-center gap-2">
              <span class="text-sm text-text-secondary">View:</span>
              <div class="flex gap-1">
                <button
                  :for={range <- ~w(hourly daily monthly)}
                  type="button"
                  phx-click="set_time_range"
                  phx-value-range={range}
                  class={[
                    "px-3 py-1.5 rounded-lg text-sm font-medium transition-colors",
                    @time_range == range && "bg-accent-purple text-white",
                    @time_range != range &&
                      "bg-bg-surface text-text-secondary hover:text-text-primary hover:bg-bg-muted"
                  ]}
                >
                  {String.capitalize(range)}
                </button>
              </div>
            </div>

            <%!-- Volume Chart --%>
            <div class="mt-6 bg-bg-elevated border border-border-default rounded-lg p-6">
              <h3 class="text-lg font-semibold text-text-primary mb-4">
                Log Volume - {String.capitalize(@time_range)}
              </h3>
              <div
                id="volume-chart"
                phx-hook=".VolumeChart"
                phx-update="ignore"
                class="w-full h-80"
              >
              </div>
            </div>

            <%!-- Data Table --%>
            <div class="mt-8 bg-bg-elevated border border-border-default rounded-lg overflow-hidden">
              <div class="px-6 py-4 border-b border-border-default">
                <h3 class="text-lg font-semibold text-text-primary">
                  Volume Breakdown
                </h3>
              </div>
              <div class="overflow-x-auto">
                <table class="w-full">
                  <thead class="bg-bg-surface">
                    <tr>
                      <th class="px-6 py-3 text-left text-xs font-medium text-text-tertiary uppercase tracking-wider">
                        Period
                      </th>
                      <th class="px-6 py-3 text-right text-xs font-medium text-text-tertiary uppercase tracking-wider">
                        Log Count
                      </th>
                      <th class="px-6 py-3 text-right text-xs font-medium text-text-tertiary uppercase tracking-wider">
                        Volume
                      </th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-border-subtle">
                    <tr
                      :for={{period, count, bytes} <- table_data(@time_range, assigns)}
                      class="hover:bg-bg-surface/50"
                    >
                      <td class="px-6 py-3 text-sm text-text-primary font-mono">
                        {format_period(period, @time_range)}
                      </td>
                      <td class="px-6 py-3 text-sm text-text-secondary text-right tabular-nums">
                        {format_count(count)}
                      </td>
                      <td class="px-6 py-3 text-sm text-text-secondary text-right tabular-nums">
                        {format_bytes(bytes || 0)}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".VolumeChart">
      export default {
        mounted() {
          this.chart = echarts.init(this.el, null, { renderer: 'canvas' })

          this.handleEvent("chart-data", ({data}) => {
            this.renderChart(data)
          })

          this.resizeObserver = new ResizeObserver(() => {
            this.chart.resize()
          })
          this.resizeObserver.observe(this.el)
        },

        destroyed() {
          if (this.resizeObserver) {
            this.resizeObserver.disconnect()
          }
          if (this.chart) {
            this.chart.dispose()
          }
        },

        renderChart(data) {
          const option = {
            tooltip: {
              trigger: 'axis',
              backgroundColor: '#252542',
              borderColor: '#363654',
              textStyle: { color: '#f8f8fc' },
              formatter: (params) => {
                const point = params[0]
                return `${point.name}<br/>
                  <span style="color:#7c3aed">Count:</span> ${this.formatCount(point.value)}<br/>
                  <span style="color:#60a5fa">Volume:</span> ${this.formatBytes(data.bytes[point.dataIndex])}`
              }
            },
            grid: {
              left: '3%',
              right: '4%',
              bottom: '3%',
              top: '10%',
              containLabel: true
            },
            xAxis: {
              type: 'category',
              data: data.labels,
              axisLine: { lineStyle: { color: '#363654' } },
              axisLabel: { color: '#6b6b80', fontSize: 11 },
              axisTick: { show: false }
            },
            yAxis: [
              {
                type: 'value',
                name: 'Count',
                nameTextStyle: { color: '#6b6b80' },
                axisLine: { show: false },
                axisLabel: {
                  color: '#6b6b80',
                  fontSize: 11,
                  formatter: (val) => this.formatCount(val)
                },
                splitLine: { lineStyle: { color: '#2d2d4a' } }
              }
            ],
            series: [
              {
                name: 'Log Count',
                type: 'bar',
                data: data.counts,
                itemStyle: {
                  color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
                    { offset: 0, color: '#7c3aed' },
                    { offset: 1, color: '#6d28d9' }
                  ]),
                  borderRadius: [4, 4, 0, 0]
                },
                emphasis: {
                  itemStyle: {
                    color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
                      { offset: 0, color: '#8b5cf6' },
                      { offset: 1, color: '#7c3aed' }
                    ])
                  }
                }
              }
            ]
          }

          this.chart.setOption(option)
        },

        formatCount(num) {
          if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M'
          if (num >= 1000) return (num / 1000).toFixed(1) + 'K'
          return num.toString()
        },

        formatBytes(bytes) {
          if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(2) + ' GB'
          if (bytes >= 1048576) return (bytes / 1048576).toFixed(2) + ' MB'
          if (bytes >= 1024) return (bytes / 1024).toFixed(2) + ' KB'
          return bytes + ' B'
        }
      }
    </script>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :subtitle, :string, required: true
  attr :icon, :string, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="bg-bg-elevated border border-border-default rounded-lg p-5">
      <div class="flex items-center gap-3">
        <div class="p-2 bg-accent-purple/10 rounded-lg">
          <.icon name={@icon} class="size-5 text-accent-purple" />
        </div>
        <div>
          <p class="text-sm text-text-tertiary">{@title}</p>
          <p class="text-2xl font-semibold text-text-primary">{@value}</p>
          <p class="text-xs text-text-tertiary mt-0.5">{@subtitle}</p>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("set_time_range", %{"range" => range}, socket) do
    data = chart_data(range, socket.assigns)

    {:noreply,
     socket
     |> assign(:time_range, range)
     |> push_event("chart-data", %{data: data})}
  end

  defp chart_data("hourly", %{hourly_data: data}), do: build_chart_map(data, "hourly")
  defp chart_data("daily", %{daily_data: data}), do: build_chart_map(data, "daily")
  defp chart_data("monthly", %{monthly_data: data}), do: build_chart_map(data, "monthly")

  # Accept both assigns map and metrics map
  defp chart_data(range, assigns) when is_map(assigns) do
    data = Map.get(assigns, String.to_existing_atom("#{range}_data"), [])
    build_chart_map(data, range)
  end

  defp table_data("hourly", assigns), do: Enum.reverse(assigns.hourly_data)
  defp table_data("daily", assigns), do: Enum.reverse(assigns.daily_data)
  defp table_data("monthly", assigns), do: Enum.reverse(assigns.monthly_data)

  defp build_chart_map(data, range) do
    labels = Enum.map(data, fn {dt, _, _} -> format_chart_label(dt, range) end)
    counts = Enum.map(data, fn {_, count, _} -> count end)
    bytes = Enum.map(data, fn {_, _, b} -> b || 0 end)

    %{labels: labels, counts: counts, bytes: bytes}
  end

  defp format_count(nil), do: "0"

  defp format_count(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_count(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_count(n) when is_integer(n), do: Integer.to_string(n)
  defp format_count(n) when is_float(n), do: format_count(round(n))

  defp format_bytes(nil), do: "0 B"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 2)} MB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1024,
    do: "#{Float.round(bytes / 1024, 2)} KB"

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(bytes) when is_float(bytes), do: format_bytes(round(bytes))

  defp format_period(datetime, "hourly") do
    Calendar.strftime(datetime, "%m/%d %H:00")
  end

  defp format_period(datetime, "daily") do
    Calendar.strftime(datetime, "%b %d, %Y")
  end

  defp format_period(datetime, "monthly") do
    Calendar.strftime(datetime, "%B %Y")
  end

  defp format_chart_label(datetime, "hourly"), do: Calendar.strftime(datetime, "%H:00")
  defp format_chart_label(datetime, "daily"), do: Calendar.strftime(datetime, "%m/%d")
  defp format_chart_label(datetime, "monthly"), do: Calendar.strftime(datetime, "%b")
end
