// Custom ECharts build - only include what we need for metrics
import * as echarts from "echarts/core"
import { BarChart } from "echarts/charts"
import { GridComponent, TooltipComponent } from "echarts/components"
import { CanvasRenderer } from "echarts/renderers"

// Register only what we use
echarts.use([BarChart, GridComponent, TooltipComponent, CanvasRenderer])

export default echarts
