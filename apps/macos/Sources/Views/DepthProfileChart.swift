import SwiftUI
import DivelogCore

struct DepthProfileChart: View {
    let samples: [DiveSample]

    private var maxDepth: Float {
        samples.map(\.depthM).max() ?? 30
    }

    private var maxTime: Int32 {
        samples.map(\.tSec).max() ?? 3600
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let padding: CGFloat = 40

            ZStack {
                // Grid lines
                gridLines(width: width, height: height, padding: padding)

                // Depth profile path
                depthPath(width: width, height: height, padding: padding)
                    .stroke(Color.blue, lineWidth: 2)

                // Fill under the curve
                depthPath(width: width, height: height, padding: padding, closed: true)
                    .fill(LinearGradient(
                        colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))

                // Axis labels
                axisLabels(width: width, height: height, padding: padding)
            }
        }
    }

    private func gridLines(width: CGFloat, height: CGFloat, padding: CGFloat) -> some View {
        let chartWidth = width - padding * 2
        let chartHeight = height - padding * 2

        return ZStack {
            // Horizontal grid lines (depth)
            ForEach(0..<5) { i in
                let y = padding + (chartHeight / 4) * CGFloat(i)
                Path { path in
                    path.move(to: CGPoint(x: padding, y: y))
                    path.addLine(to: CGPoint(x: width - padding, y: y))
                }
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            }

            // Vertical grid lines (time)
            ForEach(0..<5) { i in
                let x = padding + (chartWidth / 4) * CGFloat(i)
                Path { path in
                    path.move(to: CGPoint(x: x, y: padding))
                    path.addLine(to: CGPoint(x: x, y: height - padding))
                }
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            }
        }
    }

    private func depthPath(width: CGFloat, height: CGFloat, padding: CGFloat, closed: Bool = false) -> Path {
        let chartWidth = width - padding * 2
        let chartHeight = height - padding * 2

        return Path { path in
            guard !samples.isEmpty else { return }

            let points = samples.map { sample -> CGPoint in
                let x = padding + (CGFloat(sample.tSec) / CGFloat(maxTime)) * chartWidth
                let y = padding + (CGFloat(sample.depthM) / CGFloat(maxDepth)) * chartHeight
                return CGPoint(x: x, y: y)
            }

            path.move(to: points[0])

            for point in points.dropFirst() {
                path.addLine(to: point)
            }

            if closed {
                // Close the path along the bottom
                path.addLine(to: CGPoint(x: points.last!.x, y: height - padding))
                path.addLine(to: CGPoint(x: points.first!.x, y: height - padding))
                path.closeSubpath()
            }
        }
    }

    private func axisLabels(width: CGFloat, height: CGFloat, padding: CGFloat) -> some View {
        let chartWidth = width - padding * 2
        let chartHeight = height - padding * 2

        return ZStack {
            // Depth labels (left side)
            ForEach(0..<5) { i in
                let depth = (Float(i) / 4.0) * maxDepth
                let y = padding + (chartHeight / 4) * CGFloat(i)
                Text(String(format: "%.0fm", depth))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .position(x: padding - 20, y: y)
            }

            // Time labels (bottom)
            ForEach(0..<5) { i in
                let time = (Int32(i) * maxTime) / 4
                let x = padding + (chartWidth / 4) * CGFloat(i)
                Text("\(time / 60)m")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .position(x: x, y: height - padding + 15)
            }
        }
    }
}
