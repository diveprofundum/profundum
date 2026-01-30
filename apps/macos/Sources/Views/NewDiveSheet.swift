import SwiftUI
import DivelogCore

struct NewDiveSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState

    @State private var devices: [Device] = []
    @State private var selectedDeviceId: String?

    @State private var startDate = Date()
    @State private var durationMinutes = 60
    @State private var maxDepth = 30.0
    @State private var avgDepth = 18.0
    @State private var bottomTimeMinutes = 50

    @State private var isCCR = false
    @State private var decoRequired = false
    @State private var cnsPercent: Double = 0
    @State private var otu: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Dive")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Form
            Form {
                Section("Basic Info") {
                    Picker("Device", selection: $selectedDeviceId) {
                        Text("Select device").tag(nil as String?)
                        ForEach(devices, id: \.id) { device in
                            Text(device.model).tag(device.id as String?)
                        }
                    }

                    DatePicker("Start Time", selection: $startDate)

                    Stepper("Duration: \(durationMinutes) min", value: $durationMinutes, in: 1...600)
                }

                Section("Depth & Time") {
                    HStack {
                        Text("Max Depth")
                        Spacer()
                        TextField("m", value: $maxDepth, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("m")
                    }

                    HStack {
                        Text("Avg Depth")
                        Spacer()
                        TextField("m", value: $avgDepth, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("m")
                    }

                    Stepper("Bottom Time: \(bottomTimeMinutes) min", value: $bottomTimeMinutes, in: 1...600)
                }

                Section("Dive Type") {
                    Toggle("CCR Dive", isOn: $isCCR)
                    Toggle("Deco Required", isOn: $decoRequired)
                }

                Section("Exposure") {
                    HStack {
                        Text("CNS %")
                        Spacer()
                        TextField("", value: $cnsPercent, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }

                    HStack {
                        Text("OTU")
                        Spacer()
                        TextField("", value: $otu, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save Dive") {
                    saveDive()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedDeviceId == nil)
            }
            .padding()
        }
        .frame(width: 500, height: 600)
        .task {
            do {
                devices = try appState.diveService.listDevices()
            } catch {
                print("Failed to load devices: \(error)")
            }
        }
    }

    private func saveDive() {
        guard let deviceId = selectedDeviceId else { return }

        let startUnix = Int64(startDate.timeIntervalSince1970)
        let endUnix = startUnix + Int64(durationMinutes * 60)

        let dive = Dive(
            deviceId: deviceId,
            startTimeUnix: startUnix,
            endTimeUnix: endUnix,
            maxDepthM: Float(maxDepth),
            avgDepthM: Float(avgDepth),
            bottomTimeSec: Int32(bottomTimeMinutes * 60),
            isCcr: isCCR,
            decoRequired: decoRequired,
            cnsPercent: Float(cnsPercent),
            otu: Float(otu)
        )

        do {
            try appState.diveService.saveDive(dive, tags: [], buddyIds: [], equipmentIds: [])
            dismiss()
        } catch {
            print("Failed to save dive: \(error)")
        }
    }
}
