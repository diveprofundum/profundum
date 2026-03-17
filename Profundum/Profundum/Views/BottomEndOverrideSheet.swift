import DivelogCore
import SwiftUI

struct BottomEndOverrideSheet: View {
    let dive: Dive
    let samples: [DiveSample]
    let autoBottomEndT: Int32
    let depthUnit: DepthUnit
    let onSave: (Int32?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var minutes: Int
    @State private var seconds: Int

    init(
        dive: Dive, samples: [DiveSample], autoBottomEndT: Int32,
        depthUnit: DepthUnit, onSave: @escaping (Int32?) -> Void
    ) {
        self.dive = dive
        self.samples = samples
        self.autoBottomEndT = autoBottomEndT
        self.depthUnit = depthUnit
        self.onSave = onSave

        let initial = dive.bottomEndTOverrideSec ?? autoBottomEndT
        _minutes = State(initialValue: Int(initial) / 60)
        _seconds = State(initialValue: Int(initial) % 60)
    }

    private var overrideSeconds: Int32 {
        Int32(max(0, minutes) * 60 + max(0, min(59, seconds)))
    }

    private var depthAtOverride: String {
        let t = overrideSeconds
        guard !samples.isEmpty else { return "—" }
        // Find bracketing samples and interpolate
        if let exact = samples.first(where: { $0.tSec == t }) {
            return UnitFormatter.formatDepth(exact.depthM, unit: depthUnit)
        }
        guard let afterIdx = samples.firstIndex(where: { $0.tSec >= t }) else {
            let last = samples[samples.count - 1]
            return UnitFormatter.formatDepth(last.depthM, unit: depthUnit)
        }
        if afterIdx == 0 {
            return UnitFormatter.formatDepth(samples[0].depthM, unit: depthUnit)
        }
        let before = samples[afterIdx - 1]
        let after = samples[afterIdx]
        let range = after.tSec - before.tSec
        guard range > 0 else {
            return UnitFormatter.formatDepth(before.depthM, unit: depthUnit)
        }
        let frac = Float(t - before.tSec) / Float(range)
        let depth = before.depthM + (after.depthM - before.depthM) * frac
        return UnitFormatter.formatDepth(depth, unit: depthUnit)
    }

    private var isModified: Bool {
        overrideSeconds != autoBottomEndT
    }

    private var isValid: Bool {
        overrideSeconds > 0 && overrideSeconds <= maxSeconds
    }

    private var hasExistingOverride: Bool {
        dive.bottomEndTOverrideSec != nil
    }

    private var maxSeconds: Int32 {
        samples.last?.tSec ?? Int32(dive.endTimeUnix - dive.startTimeUnix)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Auto-detected context
                VStack(spacing: 4) {
                    Text("Auto-Detected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatTime(autoBottomEndT))
                        .font(.title2)
                        .fontWeight(.semibold)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)

                // Time input
                VStack(spacing: 12) {
                    Text("Override Value")
                        .font(.headline)

                    HStack(spacing: 16) {
                        VStack(spacing: 4) {
                            Text("Minutes")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack {
                                Button {
                                    if minutes > 0 { minutes -= 1 }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Decrease minutes")

                                TextField("", value: $minutes, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 60)
                                    .multilineTextAlignment(.center)
                                    #if os(iOS)
                                    .keyboardType(.numberPad)
                                    #endif
                                    .accessibilityLabel("Minutes")

                                Button {
                                    if Int32(minutes + 1) * 60 <= maxSeconds {
                                        minutes += 1
                                    }
                                } label: {
                                    Image(systemName: "plus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Increase minutes")
                            }
                        }

                        Text(":")
                            .font(.title2)
                            .padding(.top, 16)
                            .accessibilityHidden(true)

                        VStack(spacing: 4) {
                            Text("Seconds")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack {
                                Button {
                                    if seconds > 0 {
                                        seconds -= 1
                                    } else if minutes > 0 {
                                        minutes -= 1
                                        seconds = 59
                                    }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Decrease seconds")

                                TextField("", value: $seconds, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 60)
                                    .multilineTextAlignment(.center)
                                    #if os(iOS)
                                    .keyboardType(.numberPad)
                                    #endif
                                    .accessibilityLabel("Seconds")

                                Button {
                                    if seconds < 59 {
                                        seconds += 1
                                    } else {
                                        seconds = 0
                                        minutes += 1
                                    }
                                } label: {
                                    Image(systemName: "plus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Increase seconds")
                            }
                        }
                    }
                }

                // Live depth preview
                VStack(spacing: 4) {
                    Text("Depth at \(formatTime(overrideSeconds))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(depthAtOverride)
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(12)
                .accessibilityElement(children: .combine)

                Spacer()

                // Actions
                VStack(spacing: 12) {
                    if isModified && isValid {
                        Button("Save") {
                            onSave(overrideSeconds)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    }

                    if hasExistingOverride {
                        Button("Use Auto-Detected") {
                            onSave(nil)
                            dismiss()
                        }
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding()
            .navigationTitle("Bottom End Override")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            #endif
            .onChange(of: minutes) { _, newValue in
                minutes = max(0, newValue)
            }
            .onChange(of: seconds) { _, newValue in
                seconds = max(0, min(59, newValue))
            }
        }
    }

    private func formatTime(_ totalSec: Int32) -> String {
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%d:%02d", m, s)
    }
}
