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
    let hasCeilingData: Bool
    let ceilingPoints: [CeilingDataPoint]

    init(samples: [DiveSample], depthUnit: DepthUnit, temperatureUnit: TemperatureUnit) {
        var maxD: Float = 0
        var minC: Float = .greatestFiniteMagnitude
        var maxC: Float = -.greatestFiniteMagnitude

        // First pass: find extremes
        for s in samples {
            let d = UnitFormatter.depth(s.depthM, unit: depthUnit)
            if d > maxD { maxD = d }
            let c = s.tempC
            if c < minC { minC = c }
            if c > maxC { maxC = c }
        }

        if maxD < 1 { maxD = 30 }
        self.maxDepth = maxD

        // Downsample depth to ~300 points
        let depthStride = max(1, samples.count / 300)
        var depths: [DepthDataPoint] = []
        depths.reserveCapacity(302)
        var di = 0
        var depthIdx = 0
        while di < samples.count {
            let t = Float(samples[di].tSec) / 60.0
            let d = UnitFormatter.depth(samples[di].depthM, unit: depthUnit)
            depths.append(DepthDataPoint(id: depthIdx, timeMinutes: t, depth: d))
            depthIdx += 1
            di += depthStride
        }
        // Always include last sample
        if let last = samples.last {
            let lastT = Float(last.tSec) / 60.0
            if depths.last?.timeMinutes != lastT {
                let d = UnitFormatter.depth(last.depthM, unit: depthUnit)
                depths.append(DepthDataPoint(id: depthIdx, timeMinutes: lastT, depth: d))
            }
        }

        self.depthPoints = depths
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
            var tempIdx = 0
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
                temps.append(TempDataPoint(id: tempIdx, timeMinutes: t, normalizedValue: normalized))
                tempIdx += 1
                i += stride
            }
            // Always include last sample
            if let last = samples.last {
                let lastT = Float(last.tSec) / 60.0
                if temps.last?.timeMinutes != lastT {
                    let display = UnitFormatter.temperature(last.tempC, unit: temperatureUnit)
                    let fraction = (display - range.min) / (range.max - range.min)
                    let normalized = -(maxD * (1.0 - fraction))
                    temps.append(TempDataPoint(id: tempIdx, timeMinutes: lastT, normalizedValue: normalized))
                }
            }
            self.tempPoints = temps
        } else {
            self.tempDisplayRange = nil
            self.tempPoints = []
        }

        // Ceiling pass: downsample to ~300 points, no smoothing.
        // Emit zero-ceiling points at deco boundaries so AreaMark closes cleanly.
        let anyCeiling = samples.contains { ($0.ceilingM ?? 0) > 0 }
        self.hasCeilingData = anyCeiling
        if anyCeiling {
            let cStride = max(1, samples.count / 300)
            var cPoints: [CeilingDataPoint] = []
            cPoints.reserveCapacity(302)
            var ci = 0
            var cIdx = 0
            var wasInDeco = false
            while ci < samples.count {
                let cm = samples[ci].ceilingM ?? 0
                let t = Float(samples[ci].tSec) / 60.0
                if cm > 0 {
                    if !wasInDeco {
                        // Entering deco — emit a zero point to start the area cleanly
                        cPoints.append(CeilingDataPoint(id: cIdx, timeMinutes: t, ceilingDepth: 0))
                        cIdx += 1
                    }
                    let d = UnitFormatter.depth(cm, unit: depthUnit)
                    cPoints.append(CeilingDataPoint(id: cIdx, timeMinutes: t, ceilingDepth: d))
                    cIdx += 1
                    wasInDeco = true
                } else if wasInDeco {
                    // Exiting deco — emit a zero point to close the area
                    cPoints.append(CeilingDataPoint(id: cIdx, timeMinutes: t, ceilingDepth: 0))
                    cIdx += 1
                    wasInDeco = false
                }
                ci += cStride
            }
            // Always include last sample
            if let last = samples.last {
                let lastT = Float(last.tSec) / 60.0
                let cm = last.ceilingM ?? 0
                if cPoints.last?.timeMinutes != lastT {
                    if cm > 0 {
                        let d = UnitFormatter.depth(cm, unit: depthUnit)
                        cPoints.append(CeilingDataPoint(id: cIdx, timeMinutes: lastT, ceilingDepth: d))
                    } else if wasInDeco {
                        cPoints.append(CeilingDataPoint(id: cIdx, timeMinutes: lastT, ceilingDepth: 0))
                    }
                }
            }
            self.ceilingPoints = cPoints
        } else {
            self.ceilingPoints = []
        }
    }

    /// Padded Y domain bounds (negative depth scale).
    var domainMin: Float { -(maxDepth * 1.15) }
    var domainMax: Float { maxDepth * 0.05 }

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

    /// Accurate depth display string from full-resolution samples.
    func nearestDepthDisplay(to time: Float, samples: [DiveSample], unit: DepthUnit) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        return UnitFormatter.formatDepth(samples[idx].depthM, unit: unit)
    }

    /// Elapsed dive time for the nearest sample, formatted as mm:ss.
    func nearestElapsedTime(to time: Float, samples: [DiveSample]) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        let totalSec = Int(samples[idx].tSec)
        let minutes = totalSec / 60
        let seconds = totalSec % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Temperature display string for the nearest sample.
    func nearestTempDisplay(to time: Float, samples: [DiveSample], unit: TemperatureUnit) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        return UnitFormatter.formatTemperature(samples[idx].tempC, unit: unit)
    }

    /// Binary search returning the nearest sample to a given time.
    func nearestSampleIndex(to time: Float, in samples: [DiveSample]) -> Int? {
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
        if lo > 0 {
            let prevTime = Float(samples[lo - 1].tSec) / 60.0
            let currTime = Float(samples[lo].tSec) / 60.0
            if abs(prevTime - time) < abs(currTime - time) {
                return lo - 1
            }
        }
        return lo
    }

    /// Ceiling display string for the nearest sample.
    func nearestCeilingDisplay(to time: Float, samples: [DiveSample], unit: DepthUnit) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        guard let cm = samples[idx].ceilingM, cm > 0 else { return nil }
        return UnitFormatter.formatDepth(cm, unit: unit)
    }

    /// TTS display string for the nearest sample.
    func nearestTtsDisplay(to time: Float, samples: [DiveSample]) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        guard let tts = samples[idx].ttsSec, tts > 0 else { return nil }
        let minutes = tts / 60
        let seconds = tts % 60
        if minutes > 0 {
            return "\(minutes):\(String(format: "%02d", seconds))"
        }
        return "\(seconds)s"
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

    private var selectedDepthDisplay: String? {
        guard let selectedTime, let data = chartData else { return nil }
        return data.nearestDepthDisplay(to: selectedTime, samples: samples, unit: depthUnit)
    }

    private var selectedElapsedTime: String? {
        guard let selectedTime, let data = chartData else { return nil }
        return data.nearestElapsedTime(to: selectedTime, samples: samples)
    }

    private var selectedTempDisplay: String? {
        guard let selectedTime, showTemperature, let data = chartData else { return nil }
        return data.nearestTempDisplay(to: selectedTime, samples: samples, unit: temperatureUnit)
    }

    private var selectedCeilingDisplay: String? {
        guard let selectedTime, let data = chartData, data.hasCeilingData else { return nil }
        return data.nearestCeilingDisplay(to: selectedTime, samples: samples, unit: depthUnit)
    }

    private var selectedTtsDisplay: String? {
        guard let selectedTime, let data = chartData, data.hasCeilingData else { return nil }
        return data.nearestTtsDisplay(to: selectedTime, samples: samples)
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
        if data.hasCeilingData, let maxCeiling = samples.compactMap(\.ceilingM).max(), maxCeiling > 0 {
            let maxCeilingDisp = UnitFormatter.formatDepth(maxCeiling, unit: depthUnit)
            label += " Deco ceiling shown, maximum ceiling \(maxCeilingDisp)."
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
        .onChange(of: samples.count) { _, _ in
            buildChartData()
        }
        .onChange(of: depthUnit) { _, _ in
            buildChartData()
        }
        .onChange(of: temperatureUnit) { _, _ in
            buildChartData()
        }
    }

    // MARK: - Chart

    @ChartContentBuilder
    private func ceilingContent(data: DepthProfileChartData) -> some ChartContent {
        if data.hasCeilingData {
            ForEach(data.ceilingPoints) { point in
                AreaMark(
                    x: .value("Time", point.timeMinutes),
                    yStart: .value("Surface", Float(0)),
                    yEnd: .value("Ceiling", -point.ceilingDepth)
                )
                .foregroundStyle(Color.red.opacity(0.25))
            }
        }
    }

    @ChartContentBuilder
    private func depthContent(data: DepthProfileChartData) -> some ChartContent {
        ForEach(data.depthPoints) { point in
            LineMark(
                x: .value("Time", point.timeMinutes),
                y: .value("Depth", -point.depth),
                series: .value("Series", "Depth")
            )
            .foregroundStyle(Color.blue)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
    }

    @ChartContentBuilder
    private func temperatureContent(data: DepthProfileChartData) -> some ChartContent {
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
    }

    @ChartContentBuilder
    private var scrubContent: some ChartContent {
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

    private func chartContent(data: DepthProfileChartData) -> some View {
        Chart {
            depthContent(data: data)
            ceilingContent(data: data)
            temperatureContent(data: data)
            scrubContent
        }
        .chartYScale(domain: data.domainMin ... data.domainMax)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let minutes = value.as(Float.self) {
                        Text("\(Int(minutes)) min")
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
            if let depthStr = selectedDepthDisplay {
                Text(depthStr)
                    .font(isFullscreen ? .caption : .caption2)
                    .fontWeight(.semibold)
            }
            if let timeStr = selectedElapsedTime {
                Text(timeStr)
                    .font(isFullscreen ? .caption : .caption2)
                    .foregroundColor(.secondary)
            }
            if let tempStr = selectedTempDisplay {
                Text(tempStr)
                    .font(isFullscreen ? .caption : .caption2)
                    .foregroundColor(.orange)
            }
            if let ceilStr = selectedCeilingDisplay {
                Text("CEIL \(ceilStr)")
                    .font(isFullscreen ? .caption : .caption2)
                    .foregroundColor(.red)
            }
            if let ttsStr = selectedTtsDisplay {
                Text("TTS \(ttsStr)")
                    .font(isFullscreen ? .caption : .caption2)
                    .foregroundColor(.red)
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
    let id: Int
    let timeMinutes: Float
    /// Positive depth value for display (tooltip, accessibility).
    let depth: Float
}

struct TempDataPoint: Identifiable {
    let id: Int
    let timeMinutes: Float
    /// Negative normalized value for chart Y axis.
    let normalizedValue: Float
}

struct CeilingDataPoint: Identifiable {
    let id: Int
    let timeMinutes: Float
    /// Positive ceiling depth in display units.
    let ceilingDepth: Float
}
