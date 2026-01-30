import SwiftUI
import DivelogCore

struct NewDiveSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState

    @State private var devices: [Device] = []
    @State private var selectedDeviceId: String?

    @State private var startDate = Date()
    @State private var durationMinutes: Double = 60
    @State private var maxDepth: Double = 30.0
    @State private var avgDepth: Double = 18.0
    @State private var bottomTimeMinutes: Double = 50

    @State private var isCCR = false
    @State private var decoRequired = false
    @State private var cnsPercent: Double = 0
    @State private var otu: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Basic Info") {
                    Picker("Device", selection: $selectedDeviceId) {
                        Text("Select device").tag(nil as String?)
                        ForEach(devices, id: \.id) { device in
                            Text(device.model).tag(device.id as String?)
                        }
                    }

                    DatePicker("Start Time", selection: $startDate)

                    HStack {
                        Text("Duration")
                        Spacer()
                        Text("\(Int(durationMinutes)) min")
                    }
                    Slider(value: $durationMinutes, in: 1...180, step: 1)
                }

                Section("Depth & Time") {
                    HStack {
                        Text("Max Depth")
                        Spacer()
                        TextField("m", value: $maxDepth, format: .number)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("m")
                    }

                    HStack {
                        Text("Avg Depth")
                        Spacer()
                        TextField("m", value: $avgDepth, format: .number)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("m")
                    }

                    HStack {
                        Text("Bottom Time")
                        Spacer()
                        Text("\(Int(bottomTimeMinutes)) min")
                    }
                    Slider(value: $bottomTimeMinutes, in: 1...180, step: 1)
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
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }

                    HStack {
                        Text("OTU")
                        Spacer()
                        TextField("", value: $otu, format: .number)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                }
            }
            .navigationTitle("New Dive")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveDive()
                    }
                    .disabled(selectedDeviceId == nil)
                }
            }
            .task {
                do {
                    devices = try appState.diveService.listDevices()
                } catch {
                    print("Failed to load devices: \(error)")
                }
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
