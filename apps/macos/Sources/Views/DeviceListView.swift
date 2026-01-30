import SwiftUI
import DivelogCore

struct DeviceListView: View {
    @EnvironmentObject var appState: AppState
    @State private var devices: [Device] = []
    @State private var selectedDevice: Device?
    @State private var showAddSheet = false

    var body: some View {
        HSplitView {
            // Device list
            VStack(spacing: 0) {
                HStack {
                    Text("\(devices.count) devices")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: { showAddSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                List(devices, id: \.id, selection: $selectedDevice) { device in
                    DeviceRowView(device: device)
                        .tag(device)
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 250)

            // Detail
            if let device = selectedDevice {
                DeviceDetailView(device: device)
            } else {
                VStack {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a device")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Devices")
        .sheet(isPresented: $showAddSheet) {
            AddDeviceSheet { device in
                if let device = device {
                    devices.append(device)
                }
            }
        }
        .task {
            await loadDevices()
        }
    }

    private func loadDevices() async {
        do {
            devices = try appState.diveService.listDevices()
        } catch {
            print("Failed to load devices: \(error)")
        }
    }
}

struct DeviceRowView: View {
    let device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(device.model)
                .font(.headline)
            Text("S/N: \(device.serialNumber)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            if !device.firmwareVersion.isEmpty {
                Text("Firmware: \(device.firmwareVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DeviceDetailView: View {
    let device: Device

    var body: some View {
        Form {
            Section("Device Information") {
                LabeledContent("Model", value: device.model)
                LabeledContent("Serial Number", value: device.serialNumber)
                if !device.firmwareVersion.isEmpty {
                    LabeledContent("Firmware", value: device.firmwareVersion)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AddDeviceSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var model = ""
    @State private var serialNumber = ""
    @State private var firmwareVersion = ""

    let onSave: (Device?) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Device")
                .font(.title2)

            Form {
                TextField("Model", text: $model)
                TextField("Serial Number", text: $serialNumber)
                TextField("Firmware Version", text: $firmwareVersion)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                    onSave(nil)
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    let device = Device(
                        model: model,
                        serialNumber: serialNumber,
                        firmwareVersion: firmwareVersion
                    )
                    do {
                        try appState.diveService.saveDevice(device)
                        dismiss()
                        onSave(device)
                    } catch {
                        print("Failed to save device: \(error)")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isEmpty || serialNumber.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
