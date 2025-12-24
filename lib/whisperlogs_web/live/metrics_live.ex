defmodule WhisperLogsWeb.MetricsLive do
  use WhisperLogsWeb, :live_view

  alias WhisperLogs.Logs
  alias WhisperLogs.Retention

  @impl true
  def mount(_params, _session, socket) do
    total_count = Logs.count_logs()
    retention_days = Retention.retention_days()

    hourly_data = Logs.volume_by_hour(48)
    daily_data = Logs.volume_by_day(30)
    monthly_data = Logs.volume_by_month(12)

    # Calculate projections based on actual data velocity
    {projected_30d_count, projected_30d_bytes} = calculate_30d_projection()

    # Calculate total stored volume from all data
    total_bytes =
      Enum.reduce(daily_data, 0, fn {_, _, bytes}, acc -> acc + (bytes || 0) end)

    {:ok,
     socket
     |> assign(:page_title, "Metrics")
     |> assign(:total_count, total_count)
     |> assign(:total_bytes, total_bytes)
     |> assign(:retention_days, retention_days)
     |> assign(:hourly_data, hourly_data)
     |> assign(:daily_data, daily_data)
     |> assign(:monthly_data, monthly_data)
     |> assign(:projected_30d_count, projected_30d_count)
     |> assign(:projected_30d_bytes, projected_30d_bytes)
     |> assign(:time_range, "daily")}
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
              value={format_count(@projected_30d_count)}
              subtitle={"~" <> format_bytes(@projected_30d_bytes)}
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
              data-chart-data={chart_data(@time_range, assigns)}
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
        </div>
      </div>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".VolumeChart">
      export default {
        mounted() {
          this.chart = echarts.init(this.el, null, { renderer: 'canvas' })
          this.renderChart()

          this.resizeObserver = new ResizeObserver(() => {
            this.chart.resize()
          })
          this.resizeObserver.observe(this.el)
        },

        updated() {
          this.renderChart()
        },

        destroyed() {
          if (this.resizeObserver) {
            this.resizeObserver.disconnect()
          }
          if (this.chart) {
            this.chart.dispose()
          }
        },

        renderChart() {
          const data = JSON.parse(this.el.dataset.chartData)

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
    {:noreply, assign(socket, :time_range, range)}
  end

  # Calculate 30-day projection based on actual data velocity.
  # Uses up to the last 48 hours of data, but correctly handles cases
  # where less data exists (e.g., only 2 hours since first log).
  defp calculate_30d_projection do
    now = DateTime.utc_now()
    oldest = Logs.oldest_log_timestamp()

    case oldest do
      nil ->
        # No logs yet
        {0, 0}

      oldest_ts ->
        # Calculate actual hours of data we have (capped at 48 for stability)
        hours_of_data = DateTime.diff(now, oldest_ts, :second) / 3600
        sample_hours = min(hours_of_data, 48) |> max(1)

        # Get volume for the sample period
        {count, bytes} = Logs.volume_last_n_hours(ceil(sample_hours))

        # Calculate hourly velocity based on actual data span
        hourly_avg_count = count / sample_hours
        hourly_avg_bytes = bytes / sample_hours

        # Extrapolate to 30 days
        {round(hourly_avg_count * 24 * 30), round(hourly_avg_bytes * 24 * 30)}
    end
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

  defp chart_data("hourly", assigns), do: build_chart_json(assigns.hourly_data, "hourly")
  defp chart_data("daily", assigns), do: build_chart_json(assigns.daily_data, "daily")
  defp chart_data("monthly", assigns), do: build_chart_json(assigns.monthly_data, "monthly")

  defp table_data("hourly", assigns), do: Enum.reverse(assigns.hourly_data)
  defp table_data("daily", assigns), do: Enum.reverse(assigns.daily_data)
  defp table_data("monthly", assigns), do: Enum.reverse(assigns.monthly_data)

  defp build_chart_json(data, range) do
    labels = Enum.map(data, fn {dt, _, _} -> format_chart_label(dt, range) end)
    counts = Enum.map(data, fn {_, count, _} -> count end)
    bytes = Enum.map(data, fn {_, _, b} -> b || 0 end)

    Jason.encode!(%{labels: labels, counts: counts, bytes: bytes})
  end

  defp format_chart_label(datetime, "hourly"), do: Calendar.strftime(datetime, "%H:00")
  defp format_chart_label(datetime, "daily"), do: Calendar.strftime(datetime, "%m/%d")
  defp format_chart_label(datetime, "monthly"), do: Calendar.strftime(datetime, "%b")
end
