import DivelogCore
import SwiftUI

struct DepthProfileFullscreenView: View {
    let samples: [DiveSample]
    let depthUnit: DepthUnit
    let temperatureUnit: TemperatureUnit

    @Environment(\.dismiss) private var dismiss
    @State private var showTemperature = false
    @State private var showGf99 = false

    private var hasGf99Data: Bool {
        samples.contains { ($0.gf99 ?? 0) > 0 }
    }

    private var hasTemperatureVariation: Bool {
        let temps = samples.map(\.tempC)
        guard let lo = temps.min(), let hi = temps.max() else { return false }
        return hi - lo > 0.1
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 10) {
                Text("Dive Profile")
                    .font(.headline)

                if hasTemperatureVariation {
                    ChartOverlayChip(
                        label: "Temperature",
                        color: .orange,
                        isActive: showTemperature
                    ) {
                        showTemperature.toggle()
                    }
                }

                if hasGf99Data {
                    ChartOverlayChip(
                        label: "GF99",
                        color: .purple,
                        isActive: showGf99
                    ) {
                        showGf99.toggle()
                    }
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close fullscreen chart")
            }
            .padding()

            Divider()

            // Chart fills remaining space
            DepthProfileChart(
                samples: samples,
                depthUnit: depthUnit,
                temperatureUnit: temperatureUnit,
                showTemperature: showTemperature,
                showGf99: showGf99,
                isFullscreen: true
            )
            .frame(maxHeight: .infinity)
            .padding()
        }
        #if os(iOS)
        .background(Color(.systemBackground))
        .onAppear {
            AppDelegate.orientationLock = .landscape
            requestOrientation(.landscape)
        }
        .onDisappear {
            AppDelegate.orientationLock = .all
        }
        #else
        .background(Color(.windowBackgroundColor))
        #endif
    }

    #if os(iOS)
    private func requestOrientation(_ orientations: UIInterfaceOrientationMask) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
    }
    #endif
}
