import Charts
import DivelogCore
import SwiftUI

struct DepthProfileChart: View {
    let samples: [DiveSample]
    var depthUnit: DepthUnit = .meters
    var temperatureUnit: TemperatureUnit = .celsius

    @State private var selectedTime: Float?
    @State private var showTemperature: Bool = false

    // MARK: - Depth data

    private var chartPoints: [DepthDataPoint] {
        samples.map { s in
            DepthDataPoint(
                timeMinutes: Float(s.tSec) / 60.0,
                depth: UnitFormatter.depth(s.depthM, unit: depthUnit)
            )
        }
    }

    private var maxDepth: Float {
        chartPoints.map(\.depth).max() ?? 30
    }

    private var selectedPoint: DepthDataPoint? {
        guard let selectedTime else { return nil }
        return chartPoints.min(by: { abs($0.timeMinutes - selectedTime) < abs($1.timeMinutes - selectedTime) })
    }

    // MARK: - Temperature data

    /// True when samples contain varying temperature (more than 0.1 C spread).
    private var hasTemperatureVariation: Bool {
        let temps = samples.compactMap(\.tempC)
        guard let lo = temps.min(), let hi = temps.max() else { return false }
        return hi - lo > 0.1
    }

    /// Temperature display range (in user unit) with padding, or nil if no variation.
    private var tempDisplayRange: (min: Float, max: Float)? {
        let temps = samples.compactMap(\.tempC)
        guard let loC = temps.min(), let hiC = temps.max(), hiC - loC > 0.1 else { return nil }
        let a = UnitFormatter.temperature(loC, unit: temperatureUnit)
        let b = UnitFormatter.temperature(hiC, unit: temperatureUnit)
        let lo = min(a, b)
        let hi = max(a, b)
        let pad = (hi - lo) * 0.15
        return (min: lo - pad, max: hi + pad)
    }

    /// Normalize a Celsius temperature value to the depth Y-axis domain.
    /// Higher temperature maps to small values (top of reversed axis),
    /// lower temperature maps to large values (bottom).
    private func normalizeTemp(_ celsius: Float) -> Float {
        guard let range = tempDisplayRange else { return 0 }
        let display = UnitFormatter.temperature(celsius, unit: temperatureUnit)
        let fraction = (display - range.min) / (range.max - range.min)
        return maxDepth * (1.0 - fraction)
    }

    /// Convert a depth-domain Y value back to display temperature.
    private func denormalizeTemp(_ yValue: Float) -> Float {
        guard let range = tempDisplayRange else { return 0 }
        let fraction = 1.0 - yValue / maxDepth
        return range.min + fraction * (range.max - range.min)
    }

    private var temperaturePoints: [TempDataPoint] {
        samples.compactMap { s in
            guard let tempC = s.tempC else { return nil }
            return TempDataPoint(
                timeMinutes: Float(s.tSec) / 60.0,
                normalizedValue: normalizeTemp(tempC)
            )
        }
    }

    /// Closest sample temperature for the scrub tooltip.
    private var selectedTempDisplay: String? {
        guard let selectedTime, showTemperature else { return nil }
        guard let sample = samples
            .filter({ $0.tempC != nil })
            .min(by: { abs(Float($0.tSec) / 60.0 - selectedTime) < abs(Float($1.tSec) / 60.0 - selectedTime) }),
            let tempC = sample.tempC
        else { return nil }
        return UnitFormatter.formatTemperature(tempC, unit: temperatureUnit)
    }

    // MARK: - Accessibility

    private var chartAccessibilityLabel: String {
        let depthStr = String(format: "%.1f%@", maxDepth, UnitFormatter.depthLabel(depthUnit))
        let totalMinutes = Int((chartPoints.last?.timeMinutes ?? 0).rounded())
        var label = "Depth profile chart. Maximum depth \(depthStr) over \(totalMinutes) minutes."
        if showTemperature {
            let temps = samples.compactMap(\.tempC)
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
        VStack(spacing: 4) {
            if hasTemperatureVariation {
                HStack {
                    Spacer()
                    Button {
                        showTemperature.toggle()
                    } label: {
                        Image(systemName: "thermometer.medium")
                            .foregroundStyle(showTemperature ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showTemperature ? "Hide temperature overlay" : "Show temperature overlay")
                    .accessibilityIdentifier("temperatureToggle")
                }
                .padding(.trailing, 4)
            }

            Chart {
                ForEach(chartPoints) { point in
                    AreaMark(
                        x: .value("Time", point.timeMinutes),
                        y: .value("Depth", point.depth)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Time", point.timeMinutes),
                        y: .value("Depth", point.depth)
                    )
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }

                if showTemperature {
                    ForEach(temperaturePoints) { point in
                        LineMark(
                            x: .value("Time", point.timeMinutes),
                            y: .value("Depth", point.normalizedValue)
                        )
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }

                if let selectedPoint {
                    RuleMark(x: .value("Selected", selectedPoint.timeMinutes))
                        .foregroundStyle(Color.gray.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, spacing: 4) {
                            VStack(spacing: 2) {
                                Text(String(format: "%.1f%@", selectedPoint.depth, UnitFormatter.depthLabel(depthUnit)))
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                Text(String(format: "%.0fm", selectedPoint.timeMinutes))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                if let tempStr = selectedTempDisplay {
                                    Text(tempStr)
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                            .padding(4)
                            .background(tooltipBackground)
                            .cornerRadius(4)
                        }
                }
            }
            .chartYScale(domain: .automatic(includesZero: true, reversed: true))
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
                            Text(String(format: "%.0f%@", depth, UnitFormatter.depthLabel(depthUnit)))
                        }
                    }
                }
                if showTemperature {
                    AxisMarks(position: .trailing, values: .automatic) { value in
                        AxisValueLabel {
                            if let yVal = value.as(Float.self) {
                                let temp = denormalizeTemp(yVal)
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
        .padding(.leading, 4)
    }

    private var tooltipBackground: some ShapeStyle {
        #if os(iOS)
        Color(.systemBackground).opacity(0.9)
        #else
        Color(.windowBackgroundColor).opacity(0.9)
        #endif
    }
}

private struct DepthDataPoint: Identifiable {
    let id = UUID()
    let timeMinutes: Float
    let depth: Float
}

private struct TempDataPoint: Identifiable {
    let id = UUID()
    let timeMinutes: Float
    let normalizedValue: Float
}
