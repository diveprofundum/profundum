import SwiftUI
import DivelogCore

struct EquipmentListView: View {
    @EnvironmentObject var appState: AppState
    @State private var equipment: [Equipment] = []
    @State private var selectedEquipment: Equipment?
    @State private var showAddSheet = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("\(equipment.count) items")
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

                List(equipment, id: \.id, selection: $selectedEquipment) { item in
                    EquipmentRowView(equipment: item)
                        .tag(item)
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 250)

            if let item = selectedEquipment {
                EquipmentDetailView(equipment: item)
            } else {
                VStack {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select equipment")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Equipment")
        .sheet(isPresented: $showAddSheet) {
            AddEquipmentSheet { item in
                if let item = item {
                    equipment.append(item)
                }
            }
        }
        .task {
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
                if let notes = equipment.notes, !notes.isEmpty {
                    LabeledContent("Notes", value: notes)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AddEquipmentSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var name = ""
    @State private var kind = "Other"
    @State private var serialNumber = ""
    @State private var notes = ""

    let kinds = ["Mask", "Fins", "Wetsuit", "Drysuit", "BCD", "Regulator", "Computer", "Light", "Camera", "Tank", "Other"]

    let onSave: (Equipment?) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Equipment")
                .font(.title2)

            Form {
                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) {
                    ForEach(kinds, id: \.self) { k in
                        Text(k).tag(k)
                    }
                }
                TextField("Serial Number", text: $serialNumber)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                    onSave(nil)
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    let item = Equipment(
                        name: name,
                        kind: kind,
                        serialNumber: serialNumber.isEmpty ? nil : serialNumber,
                        notes: notes.isEmpty ? nil : notes
                    )
                    do {
                        try appState.diveService.saveEquipment(item)
                        dismiss()
                        onSave(item)
                    } catch {
                        print("Failed to save equipment: \(error)")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
