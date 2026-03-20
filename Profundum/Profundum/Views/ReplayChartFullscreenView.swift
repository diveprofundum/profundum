import DivelogCore
import SwiftUI

struct ReplayChartFullscreenView: View {
    let data: ReplayChartData
    @Bindable var controller: ReplayAnimationController
    let samples: [SampleInput]
    let depthUnit: DepthUnit

    @Environment(\.dismiss) private var dismiss
    @State private var showCeiling = true
    @State private var showGf99 = false
    @State private var showSurfGf = false

    var body: some View {
        VStack(spacing: 0) {
            // Top bar with overlay toggles
            HStack(spacing: 10) {
                Text("Replay Profile")
                    .font(.headline)

                if data.hasCeilingData {
                    ChartOverlayChip(label: "Ceiling", color: .red, isActive: showCeiling) {
                        showCeiling.toggle()
                    }
                }

                if data.hasGf99Data {
                    ChartOverlayChip(label: "GF99", color: .purple, isActive: showGf99) {
                        showGf99.toggle()
                    }
                }

                if data.hasSurfGfData {
                    ChartOverlayChip(label: "SurfGF", color: .teal, isActive: showSurfGf) {
                        showSurfGf.toggle()
                    }
                }

                Spacer()

                Button {
                    controller.pause()
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

            // Chart
            ReplayChart(
                data: data,
                visibleTimeMinutes: controller.visibleTimeMinutes,
                samples: samples,
                showCeiling: showCeiling,
                showGf99: showGf99,
                showSurfGf: showSurfGf,
                isFullscreen: true,
                depthUnit: depthUnit
            )
            .frame(maxHeight: .infinity)
            .padding(.horizontal)

            Divider()

            // Animation controls
            fullscreenControls
                .padding()
        }
        .onDisappear {
            controller.pause()
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

    private var fullscreenControls: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { controller.visibleTimeSec },
                    set: { controller.scrub(to: $0) }
                ),
                in: 0 ... max(controller.totalTimeSec, 1)
            )
            .accessibilityLabel("Animation progress")
            .accessibilityValue(controller.currentTimeLabel)

            HStack(spacing: 16) {
                Button {
                    if controller.isPlaying {
                        controller.pause()
                    } else {
                        controller.play()
                    }
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 32)
                }
                .accessibilityLabel(controller.isPlaying ? "Pause animation" : "Play animation")

                Button {
                    controller.reset()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title3)
                        .frame(width: 32)
                }
                .accessibilityLabel("Reset animation")

                Text(controller.currentTimeLabel)
                    .font(.body)
                    .monospacedDigit()
                    .foregroundColor(.secondary)

                Spacer()

                Picker("Speed", selection: Binding(
                    get: { controller.speed },
                    set: { controller.speed = $0 }
                )) {
                    ForEach(AnimationSpeed.allCases) { speed in
                        Text(speed.label).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 250)
                .accessibilityLabel("Animation speed")
            }
        }
    }

    #if os(iOS)
    private func requestOrientation(_ orientations: UIInterfaceOrientationMask) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
    }
    #endif
}
