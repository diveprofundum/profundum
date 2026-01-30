import SwiftUI
import DivelogCore

struct DeviceListView: View {
    @EnvironmentObject var appState: AppState
    @State private var devices: [Device] = []
    @State private var showAddSheet = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(devices, id: \.id) { device in
                    NavigationLink(destination: DeviceDetailView(device: device)) {
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
            }
            .listStyle(.plain)
            .navigationTitle("Devices")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showAddSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
                #else
                ToolbarItem {
                    Button(action: { showAddSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
                #endif
            }
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
            .refreshable {
                await loadDevices()
            }
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

struct DeviceDetailView: View {
    let device: Device

    var body: some View {
        List {
            Section("Device Information") {
                LabeledContent("Model", value: device.model)
                LabeledContent("Serial Number", value: device.serialNumber)
                if !device.firmwareVersion.isEmpty {
                    LabeledContent("Firmware", value: device.firmwareVersion)
                }
            }
        }
        .navigationTitle(device.model)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
        NavigationStack {
            Form {
                Section {
                    TextField("Model", text: $model)
                    TextField("Serial Number", text: $serialNumber)
                    TextField("Firmware Version", text: $firmwareVersion)
                }
            }
            .navigationTitle("Add Device")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onSave(nil)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
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
                    .disabled(model.isEmpty || serialNumber.isEmpty)
                }
            }
        }
    }
}
