import Charts
import DivelogCore
import SwiftUI

struct DepthProfileChart: View {
    let samples: [DiveSample]
    var depthUnit: DepthUnit = .meters

    @State private var selectedTime: Float?

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

    var body: some View {
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
            AxisMarks(values: .automatic) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let depth = value.as(Float.self) {
                        Text(String(format: "%.0f%@", depth, UnitFormatter.depthLabel(depthUnit)))
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
