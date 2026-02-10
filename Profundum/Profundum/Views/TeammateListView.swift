import SwiftUI
import DivelogCore

struct TeammateListView: View {
    @EnvironmentObject var appState: AppState
    @State private var teammates: [Teammate] = []
    @State private var showAddSheet = false
    @State private var editingTeammate: Teammate?

    var body: some View {
        List {
            ForEach(teammates, id: \.id) { teammate in
                NavigationLink(destination: TeammateDetailView(teammate: teammate, onEdit: {
                    editingTeammate = teammate
                })) {
                    TeammateRowView(teammate: teammate)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteTeammate(teammate)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editingTeammate = teammate
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Teammates")
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
            Task { await loadTeammates() }
        }) {
            AddTeammateSheet()
        }
        .sheet(item: $editingTeammate, onDismiss: {
            Task { await loadTeammates() }
        }) { teammate in
            AddTeammateSheet(editingTeammate: teammate)
        }
        .task {
            await loadTeammates()
        }
        .refreshable {
            await loadTeammates()
        }
    }

    private func loadTeammates() async {
        do {
            teammates = try appState.diveService.listTeammates()
        } catch {
            print("Failed to load teammates: \(error)")
        }
    }

    private func deleteTeammate(_ teammate: Teammate) {
        do {
            _ = try appState.diveService.deleteTeammate(id: teammate.id)
            teammates.removeAll { $0.id == teammate.id }
        } catch {
            print("Failed to delete teammate: \(error)")
        }
    }
}

struct TeammateRowView: View {
    let teammate: Teammate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(teammate.displayName)
                .font(.headline)
            if let cert = teammate.certificationLevel, !cert.isEmpty {
                Text(cert)
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            if let contact = teammate.contact, !contact.isEmpty {
                Text(contact)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct TeammateDetailView: View {
    let teammate: Teammate
    var onEdit: (() -> Void)?

    var body: some View {
        Form {
            Section("Teammate Information") {
                LabeledContent("Name", value: teammate.displayName)
                if let cert = teammate.certificationLevel, !cert.isEmpty {
                    LabeledContent("Certification", value: cert)
                }
                if let contact = teammate.contact, !contact.isEmpty {
                    LabeledContent("Contact", value: contact)
                }
            }

            if let notes = teammate.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                        .foregroundColor(.secondary)
                }
            }

            if onEdit != nil {
                Section {
                    Button("Edit Teammate") {
                        onEdit?()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(teammate.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct AddTeammateSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var displayName = ""
    @State private var certificationLevel = ""
    @State private var contact = ""
    @State private var notes = ""

    var editingTeammate: Teammate?

    private var sheetTitle: String {
        editingTeammate != nil ? "Edit Teammate" : "Add Teammate"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $displayName)
                    TextField("Certification Level", text: $certificationLevel)
                    TextField("Contact (email/phone)", text: $contact)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        #endif
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
            .frame(minWidth: 400, idealWidth: 500, minHeight: 350)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveTeammate()
                    }
                    .disabled(displayName.isEmpty)
                }
            }
            .onAppear {
                if let tm = editingTeammate {
                    displayName = tm.displayName
                    certificationLevel = tm.certificationLevel ?? ""
                    contact = tm.contact ?? ""
                    notes = tm.notes ?? ""
                }
            }
        }
    }

    private func saveTeammate() {
        let teammate = Teammate(
            id: editingTeammate?.id ?? UUID().uuidString,
            displayName: displayName,
            contact: contact.isEmpty ? nil : contact,
            certificationLevel: certificationLevel.isEmpty ? nil : certificationLevel,
            notes: notes.isEmpty ? nil : notes
        )
        do {
            try appState.diveService.saveTeammate(teammate)
            dismiss()
        } catch {
            print("Failed to save teammate: \(error)")
        }
    }
}
