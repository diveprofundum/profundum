import Charts
import DivelogCore
import SwiftUI

// MARK: - Precomputed chart data

struct DepthProfileChartData {
    let depthPoints: [DepthDataPoint]
    /// Positive max depth value (for display / tooltip).
    let maxDepth: Float
    let totalMinutes: Float
    let hasTemperatureVariation: Bool
    let tempDisplayRange: (min: Float, max: Float)?
    let tempPoints: [TempDataPoint]

    init(samples: [DiveSample], depthUnit: DepthUnit, temperatureUnit: TemperatureUnit) {
        var depths: [DepthDataPoint] = []
        depths.reserveCapacity(samples.count)
        var maxD: Float = 0
        var minC: Float = .greatestFiniteMagnitude
        var maxC: Float = -.greatestFiniteMagnitude

        // Single pass: build depth points, track temp extremes
        for s in samples {
            let t = Float(s.tSec) / 60.0
            let d = UnitFormatter.depth(s.depthM, unit: depthUnit)
            depths.append(DepthDataPoint(timeMinutes: t, depth: d))
            if d > maxD { maxD = d }
            let c = s.tempC
            if c < minC { minC = c }
            if c > maxC { maxC = c }
        }

        if maxD < 1 { maxD = 30 }

        self.depthPoints = depths
        self.maxDepth = maxD
        self.totalMinutes = depths.last?.timeMinutes ?? 0

        let hasVariation = maxC - minC > 0.1 && !samples.isEmpty
        self.hasTemperatureVariation = hasVariation

        if hasVariation {
            let a = UnitFormatter.temperature(minC, unit: temperatureUnit)
            let b = UnitFormatter.temperature(maxC, unit: temperatureUnit)
            let lo = min(a, b)
            let hi = max(a, b)
            let pad = (hi - lo) * 0.15
            let range = (min: lo - pad, max: hi + pad)
            self.tempDisplayRange = range

            // Second pass: smooth + downsample temp to ~300 points
            // Stride controls output count; window controls smoothing independently.
            // Temperature sensors have thermal mass — real changes happen over minutes,
            // so a ~1-2 min window removes integer-resolution noise without losing thermoclines.
            let targetCount = 300
            let stride = max(1, samples.count / targetCount)
            let halfWindow = max(5, samples.count / 40)
            var temps: [TempDataPoint] = []
            temps.reserveCapacity(targetCount + 2)
            var i = 0
            while i < samples.count {
                let t = Float(samples[i].tSec) / 60.0
                let wStart = max(0, i - halfWindow)
                let wEnd = min(samples.count - 1, i + halfWindow)
                var tempSum: Float = 0
                for j in wStart ... wEnd {
                    tempSum += samples[j].tempC
                }
                let avgC = tempSum / Float(wEnd - wStart + 1)
                let display = UnitFormatter.temperature(avgC, unit: temperatureUnit)
                let fraction = (display - range.min) / (range.max - range.min)
                let normalized = -(maxD * (1.0 - fraction))
                temps.append(TempDataPoint(timeMinutes: t, normalizedValue: normalized))
                i += stride
            }
            // Always include last sample
            if let last = samples.last {
                let lastT = Float(last.tSec) / 60.0
                if temps.last?.timeMinutes != lastT {
                    let display = UnitFormatter.temperature(last.tempC, unit: temperatureUnit)
                    let fraction = (display - range.min) / (range.max - range.min)
                    let normalized = -(maxD * (1.0 - fraction))
                    temps.append(TempDataPoint(timeMinutes: lastT, normalizedValue: normalized))
                }
            }
            self.tempPoints = temps
        } else {
            self.tempDisplayRange = nil
            self.tempPoints = []
        }
    }

    /// Padded Y domain lower bound (negative).
    var domainMin: Float { -(maxDepth * 1.15) }

    /// Binary search for the nearest depth point to a given time.
    func nearestDepthPoint(to time: Float) -> DepthDataPoint? {
        guard !depthPoints.isEmpty else { return nil }
        var lo = 0
        var hi = depthPoints.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if depthPoints[mid].timeMinutes < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo > 0 {
            let prev = depthPoints[lo - 1]
            let curr = depthPoints[lo]
            return abs(prev.timeMinutes - time) <= abs(curr.timeMinutes - time) ? prev : curr
        }
        return depthPoints[lo]
    }

    /// Binary search for the nearest sample temperature display string.
    func nearestTempDisplay(to time: Float, samples: [DiveSample], unit: TemperatureUnit) -> String? {
        guard !samples.isEmpty else { return nil }
        var lo = 0
        var hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if Float(samples[mid].tSec) / 60.0 < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        var best = lo
        if lo > 0 {
            let prevTime = Float(samples[lo - 1].tSec) / 60.0
            let currTime = Float(samples[lo].tSec) / 60.0
            if abs(prevTime - time) < abs(currTime - time) {
                best = lo - 1
            }
        }
        return UnitFormatter.formatTemperature(samples[best].tempC, unit: unit)
    }

    /// Denormalize a negative Y chart value back to display temperature.
    func denormalizeTemp(_ yValue: Float) -> Float {
        guard let range = tempDisplayRange else { return 0 }
        let fraction = (maxDepth + yValue) / maxDepth
        return range.min + fraction * (range.max - range.min)
    }
}

// MARK: - Chart view

struct DepthProfileChart: View {
    let samples: [DiveSample]
    var depthUnit: DepthUnit = .meters
    var temperatureUnit: TemperatureUnit = .celsius
    var showTemperature: Bool = false
    var isFullscreen: Bool = false

    @State private var chartData: DepthProfileChartData?
    @State private var selectedTime: Float?

    private var selectedPoint: DepthDataPoint? {
        guard let selectedTime, let data = chartData else { return nil }
        return data.nearestDepthPoint(to: selectedTime)
    }

    private var selectedTempDisplay: String? {
        guard let selectedTime, showTemperature, let data = chartData else { return nil }
        return data.nearestTempDisplay(to: selectedTime, samples: samples, unit: temperatureUnit)
    }

    // MARK: - Accessibility

    private var chartAccessibilityLabel: String {
        guard let data = chartData else { return "Depth profile chart" }
        let depthStr = String(format: "%.1f%@", data.maxDepth, UnitFormatter.depthLabel(depthUnit))
        let totalMinutes = Int(data.totalMinutes.rounded())
        var label = "Depth profile chart. Maximum depth \(depthStr) over \(totalMinutes) minutes."
        if showTemperature {
            let temps = samples.map(\.tempC)
            if let loC = temps.min(), let hiC = temps.max() {
                let loDisp = UnitFormatter.formatTemperature(loC, unit: temperatureUnit)
                let hiDisp = UnitFormatter.formatTemperature(hiC, unit: temperatureUnit)
                label += " Temperature overlay active, ranging from \(loDisp) to \(hiDisp)."
            }
        }
        return label
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let data = chartData {
                chartContent(data: data)
            } else {
                Color.clear
            }
        }
        .padding(.leading, 4)
        .onAppear {
            buildChartData()
        }
        .onChange(of: samples.count) { _ in
            buildChartData()
        }
        .onChange(of: depthUnit) { _ in
            buildChartData()
        }
        .onChange(of: temperatureUnit) { _ in
            buildChartData()
        }
    }

    // MARK: - Chart

    private func chartContent(data: DepthProfileChartData) -> some View {
        Chart {
            // Depth line (negative Y for natural top-down layout)
            ForEach(data.depthPoints) { point in
                LineMark(
                    x: .value("Time", point.timeMinutes),
                    y: .value("Depth", -point.depth),
                    series: .value("Series", "Depth")
                )
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            // Temperature line (separate series, already negative normalized)
            if showTemperature {
                ForEach(data.tempPoints) { point in
                    LineMark(
                        x: .value("Time", point.timeMinutes),
                        y: .value("Depth", point.normalizedValue),
                        series: .value("Series", "Temperature")
                    )
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }

            // Scrub line + tooltip
            if let selectedPoint {
                RuleMark(x: .value("Selected", selectedPoint.timeMinutes))
                    .foregroundStyle(Color.gray.opacity(isFullscreen ? 0.7 : 0.5))
                    .lineStyle(StrokeStyle(
                        lineWidth: isFullscreen ? 1.5 : 1,
                        dash: isFullscreen ? [] : [4, 4]
                    ))
                    .annotation(position: .top, spacing: 4) {
                        tooltipView
                    }
            }
        }
        .chartYScale(domain: data.domainMin ... Float(0))
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let minutes = value.as(Float.self) {
                        Text("\(Int(minutes))m")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let depth = value.as(Float.self) {
                        Text(String(format: "%.0f%@", abs(depth), UnitFormatter.depthLabel(depthUnit)))
                    }
                }
            }
            if showTemperature {
                AxisMarks(position: .trailing, values: .automatic) { value in
                    AxisValueLabel {
                        if let yVal = value.as(Float.self) {
                            let temp = data.denormalizeTemp(yVal)
                            Text(String(format: "%.1f%@", temp, UnitFormatter.temperatureLabel(temperatureUnit)))
                        }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let origin = geometry[proxy.plotAreaFrame].origin
                                let x = value.location.x - origin.x
                                if let time: Float = proxy.value(atX: x) {
                                    selectedTime = time
                                }
                            }
                            .onEnded { _ in
                                selectedTime = nil
                            }
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chartAccessibilityLabel)
    }

    // MARK: - Tooltip

    private var tooltipView: some View {
        VStack(spacing: 2) {
            if let selectedPoint {
                Text(String(format: "%.1f%@", selectedPoint.depth, UnitFormatter.depthLabel(depthUnit)))
                    .font(isFullscreen ? .caption : .caption2)
                    .fontWeight(.semibold)
            }
            if let tempStr = selectedTempDisplay {
                Text(tempStr)
                    .font(isFullscreen ? .caption : .caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding(4)
        .background(tooltipBackground)
        .cornerRadius(4)
    }

    private var tooltipBackground: some ShapeStyle {
        #if os(iOS)
        Color(.systemBackground).opacity(0.9)
        #else
        Color(.windowBackgroundColor).opacity(0.9)
        #endif
    }

    // MARK: - Helpers

    private func buildChartData() {
        chartData = DepthProfileChartData(
            samples: samples,
            depthUnit: depthUnit,
            temperatureUnit: temperatureUnit
        )
    }
}

// MARK: - Data point types

struct DepthDataPoint: Identifiable {
    let id = UUID()
    let timeMinutes: Float
    /// Positive depth value for display (tooltip, accessibility).
    let depth: Float
}

struct TempDataPoint: Identifiable {
    let id = UUID()
    let timeMinutes: Float
    /// Negative normalized value for chart Y axis.
    let normalizedValue: Float
}
