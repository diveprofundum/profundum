import SwiftUI
import DivelogCore

struct EquipmentListView: View {
    @EnvironmentObject var appState: AppState
    @State private var equipment: [Equipment] = []
    @State private var showAddSheet = false
    @State private var editingEquipment: Equipment?

    var body: some View {
        List {
            ForEach(equipment, id: \.id) { item in
                NavigationLink(destination: EquipmentDetailView(equipment: item, onEdit: {
                    editingEquipment = item
                })) {
                    EquipmentRowView(equipment: item)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteEquipment(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editingEquipment = item
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Equipment")
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
        .sheet(isPresented: $showAddSheet, onDismiss: {
            Task { await loadEquipment() }
        }) {
            AddEquipmentSheet()
        }
        .sheet(item: $editingEquipment, onDismiss: {
            Task { await loadEquipment() }
        }) { item in
            AddEquipmentSheet(editingEquipment: item)
        }
        .task {
            await loadEquipment()
        }
        .refreshable {
            await loadEquipment()
        }
    }

    private func loadEquipment() async {
        do {
            equipment = try appState.diveService.listEquipment()
        } catch {
            print("Failed to load equipment: \(error)")
        }
    }

    private func deleteEquipment(_ item: Equipment) {
        do {
            _ = try appState.diveService.deleteEquipment(id: item.id)
            equipment.removeAll { $0.id == item.id }
        } catch {
            print("Failed to delete equipment: \(error)")
        }
    }
}

struct EquipmentRowView: View {
    let equipment: Equipment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(equipment.name)
                .font(.headline)
            Text(equipment.kind)
                .font(.subheadline)
                .foregroundColor(.secondary)
            if let serial = equipment.serialNumber {
                Text("S/N: \(serial)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct EquipmentDetailView: View {
    let equipment: Equipment
    var onEdit: (() -> Void)?

    private var nextServiceInfo: (text: String, color: Color)? {
        guard let interval = equipment.serviceIntervalDays,
              let lastService = equipment.lastServiceDate else { return nil }
        let lastDate = Date(timeIntervalSince1970: TimeInterval(lastService))
        guard let nextDate = Calendar.current.date(byAdding: .day, value: interval, to: lastDate) else { return nil }
        let daysRemaining = Calendar.current.dateComponents([.day], from: Date(), to: nextDate).day ?? 0
        if daysRemaining < 0 {
            return ("Overdue by \(-daysRemaining) days", .red)
        } else if daysRemaining < 7 {
            return ("Due in \(daysRemaining) days", .red)
        } else if daysRemaining <= 30 {
            return ("Due in \(daysRemaining) days", .orange)
        } else {
            return ("Due in \(daysRemaining) days", .green)
        }
    }

    var body: some View {
        Form {
            Section("Equipment Information") {
                LabeledContent("Name", value: equipment.name)
                LabeledContent("Kind", value: equipment.kind)
                if let serial = equipment.serialNumber {
                    LabeledContent("Serial Number", value: serial)
                }
                if let interval = equipment.serviceIntervalDays {
                    LabeledContent("Service Interval", value: "\(interval) days")
                }
                if let lastService = equipment.lastServiceDate {
                    let date = Date(timeIntervalSince1970: TimeInterval(lastService))
                    LabeledContent("Last Serviced", value: date.formatted(date: .abbreviated, time: .omitted))
                }
                if let info = nextServiceInfo {
                    LabeledContent("Next Service") {
                        Text(info.text)
                            .foregroundColor(info.color)
                            .fontWeight(.medium)
                    }
                }
                if let notes = equipment.notes, !notes.isEmpty {
                    LabeledContent("Notes", value: notes)
                }
            }

            if onEdit != nil {
                Section {
                    Button("Edit Equipment") {
                        onEdit?()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(equipment.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct AddEquipmentSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var name = ""
    @State private var kind = "Other"
    @State private var serialNumber = ""
    @State private var serviceIntervalDays = ""
    @State private var hasLastServiceDate = false
    @State private var lastServiceDate = Date()
    @State private var notes = ""

    var editingEquipment: Equipment?

    let kinds = ["Mask", "Fins", "Wetsuit", "Drysuit", "BCD", "Wing", "Backplate", "Harness",
                 "Regulator", "Rebreather", "Computer", "Light", "Camera", "Canister", "Reel",
                 "SMB", "Tank", "Other"]

    private var sheetTitle: String {
        editingEquipment != nil ? "Edit Equipment" : "Add Equipment"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Kind", selection: $kind) {
                        ForEach(kinds, id: \.self) { k in
                            Text(k).tag(k)
                        }
                    }
                    TextField("Serial Number", text: $serialNumber)
                }

                Section("Service") {
                    TextField("Service Interval (days)", text: $serviceIntervalDays)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Toggle("Has Last Service Date", isOn: $hasLastServiceDate)
                    if hasLastServiceDate {
                        DatePicker("Last Serviced", selection: $lastServiceDate, displayedComponents: .date)
                    }
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(sheetTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 400, idealWidth: 500, minHeight: 400)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveEquipment()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .onAppear {
                if let eq = editingEquipment {
                    name = eq.name
                    kind = eq.kind
                    serialNumber = eq.serialNumber ?? ""
                    if let interval = eq.serviceIntervalDays {
                        serviceIntervalDays = String(interval)
                    }
                    if let lastService = eq.lastServiceDate {
                        hasLastServiceDate = true
                        lastServiceDate = Date(timeIntervalSince1970: TimeInterval(lastService))
                    }
                    notes = eq.notes ?? ""
                }
            }
        }
    }

    private func saveEquipment() {
        let item = Equipment(
            id: editingEquipment?.id ?? UUID().uuidString,
            name: name,
            kind: kind,
            serialNumber: serialNumber.isEmpty ? nil : serialNumber,
            serviceIntervalDays: Int(serviceIntervalDays),
            lastServiceDate: hasLastServiceDate ? Int64(lastServiceDate.timeIntervalSince1970) : nil,
            notes: notes.isEmpty ? nil : notes
        )
        do {
            try appState.diveService.saveEquipment(item)
            dismiss()
        } catch {
            print("Failed to save equipment: \(error)")
        }
    }
}
