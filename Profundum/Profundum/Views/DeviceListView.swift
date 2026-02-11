import DivelogCore
import SwiftUI

struct DeviceListView: View {
    @EnvironmentObject var appState: AppState
    @State private var devices: [Device] = []
    @State private var showAddSheet = false
    @State private var showArchived = false
    @State private var errorMessage: String?
    @State private var deviceToArchive: Device?
    @State private var deviceToDelete: Device?

    var body: some View {
        List {
            ForEach(devices, id: \.id) { device in
                NavigationLink(destination: DeviceDetailView(device: device, onArchive: {
                    deviceToArchive = device
                })) {
                    DeviceRowView(device: device)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deviceToDelete = device
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    if device.isActive {
                        Button {
                            deviceToArchive = device
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(.orange)
                    } else {
                        Button {
                            restoreDevice(device)
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.green)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Devices")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Show Archived", isOn: $showArchived)
                    Button(action: { showAddSheet = true }) {
                        Label("Add Device", systemImage: "plus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            #else
            ToolbarItem {
                Menu {
                    Toggle("Show Archived", isOn: $showArchived)
                    Button(action: { showAddSheet = true }) {
                        Label("Add Device", systemImage: "plus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            #endif
        }
        .sheet(isPresented: $showAddSheet, onDismiss: {
            Task { await loadDevices() }
        }) {
            AddDeviceSheet()
        }
        .task {
            await loadDevices()
        }
        .refreshable {
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
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Model", text: $model)
                    TextField("Serial Number", text: $serialNumber)
                    TextField("Firmware Version", text: $firmwareVersion)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Device")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 400, idealWidth: 500, minHeight: 300)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
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
                        } catch {
                            errorMessage = "Failed to save device: \(error.localizedDescription)"
                        }
                    }
                    .disabled(model.isEmpty || serialNumber.isEmpty)
                }
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}
