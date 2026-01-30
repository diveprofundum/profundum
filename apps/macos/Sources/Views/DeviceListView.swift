import SwiftUI
import DivelogCore

struct DeviceListView: View {
    @EnvironmentObject var appState: AppState
    @State private var devices: [Device] = []
    @State private var selectedDevice: Device?
    @State private var showAddSheet = false
    @State private var showArchived = false
    @State private var errorMessage: String?
    @State private var deviceToArchive: Device?
    @State private var deviceToDelete: Device?

    var body: some View {
        HSplitView {
            // Device list
            VStack(spacing: 0) {
                HStack {
                    Text("\(devices.count) device\(devices.count == 1 ? "" : "s")")
                        .foregroundColor(.secondary)

                    Spacer()

                    Toggle("Show Archived", isOn: $showArchived)
                        .toggleStyle(.checkbox)

                    Button(action: { Task { await loadDevices() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")

                    Button(action: { showAddSheet = true }) {
                        Image(systemName: "plus")
                    }
                    .help("Add Device")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                if devices.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No devices")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Add a dive computer to get started.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(devices, id: \.id, selection: $selectedDevice) { device in
                        DeviceRowView(device: device)
                            .tag(device)
                            .contextMenu {
                                if device.isActive {
                                    Button("Archive Device") {
                                        deviceToArchive = device
                                    }
                                } else {
                                    Button("Restore Device") {
                                        restoreDevice(device)
                                    }
                                }
                                Divider()
                                Button("Delete Device", role: .destructive) {
                                    deviceToDelete = device
                                }
                            }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 250)

            // Detail
            if let device = selectedDevice {
                DeviceDetailView(device: device, onArchive: { deviceToArchive = device })
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
                if device != nil {
                    Task { await loadDevices() }
                }
            }
        }
        .task {
            await loadDevices()
        }
        .onChange(of: showArchived) { _, _ in
            Task { await loadDevices() }
        }
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .confirmationDialog(
            "Archive Device",
            isPresented: .init(
                get: { deviceToArchive != nil },
                set: { if !$0 { deviceToArchive = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                if let device = deviceToArchive {
                    archiveDevice(device)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Archived devices are hidden but preserved for dive history. You can restore them later.")
        }
        .confirmationDialog(
            "Delete Device",
            isPresented: .init(
                get: { deviceToDelete != nil },
                set: { if !$0 { deviceToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let device = deviceToDelete {
                    deleteDevice(device)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the device. Dives associated with this device may be affected.")
        }
    }

    private func loadDevices() async {
        do {
            devices = try appState.diveService.listDevices(includeArchived: showArchived)
        } catch {
            errorMessage = "Failed to load devices: \(error.localizedDescription)"
        }
    }

    private func archiveDevice(_ device: Device) {
        do {
            _ = try appState.diveService.archiveDevice(id: device.id)
            if selectedDevice?.id == device.id {
                selectedDevice = nil
            }
            Task { await loadDevices() }
        } catch {
            errorMessage = "Failed to archive device: \(error.localizedDescription)"
        }
    }

    private func restoreDevice(_ device: Device) {
        do {
            _ = try appState.diveService.restoreDevice(id: device.id)
            Task { await loadDevices() }
        } catch {
            errorMessage = "Failed to restore device: \(error.localizedDescription)"
        }
    }

    private func deleteDevice(_ device: Device) {
        do {
            _ = try appState.diveService.deleteDevice(id: device.id)
            if selectedDevice?.id == device.id {
                selectedDevice = nil
            }
            Task { await loadDevices() }
        } catch {
            errorMessage = "Failed to delete device: \(error.localizedDescription)"
        }
    }
}

struct DeviceRowView: View {
    let device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(device.model)
                    .font(.headline)
                if !device.isActive {
                    Text("Archived")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(4)
                }
            }
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
        .opacity(device.isActive ? 1.0 : 0.6)
    }
}

struct DeviceDetailView: View {
    let device: Device
    var onArchive: (() -> Void)?

    var body: some View {
        Form {
            Section("Device Information") {
                LabeledContent("Model", value: device.model)
                LabeledContent("Serial Number", value: device.serialNumber)
                if !device.firmwareVersion.isEmpty {
                    LabeledContent("Firmware", value: device.firmwareVersion)
                }
                LabeledContent("Status", value: device.isActive ? "Active" : "Archived")
            }

            if device.isActive {
                Section {
                    Button("Archive Device") {
                        onArchive?()
                    }
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
    @State private var errorMessage: String?
    @State private var isSaving = false

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

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                    onSave(nil)
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveDevice()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isEmpty || serialNumber.isEmpty || isSaving)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func saveDevice() {
        isSaving = true
        errorMessage = nil

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
            errorMessage = "Failed to save: \(error.localizedDescription)"
            isSaving = false
        }
    }
}
