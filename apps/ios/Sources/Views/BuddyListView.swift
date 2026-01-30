import SwiftUI
import DivelogCore

struct BuddyListView: View {
    @EnvironmentObject var appState: AppState
    @State private var buddies: [Buddy] = []
    @State private var showAddSheet = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(buddies, id: \.id) { buddy in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(buddy.displayName)
                            .font(.headline)
                        if let contact = buddy.contact, !contact.isEmpty {
                            Text(contact)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Buddies")
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
                AddBuddySheet { buddy in
                    if let buddy = buddy {
                        buddies.append(buddy)
                    }
                }
            }
            .task {
                await loadBuddies()
            }
            .refreshable {
                await loadBuddies()
            }
        }
    }

    private func loadBuddies() async {
        do {
            buddies = try appState.diveService.listBuddies()
        } catch {
            print("Failed to load buddies: \(error)")
        }
    }
}

struct AddBuddySheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var displayName = ""
    @State private var contact = ""

    let onSave: (Buddy?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $displayName)
                    TextField("Contact (email/phone)", text: $contact)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        #endif
                }
            }
            .navigationTitle("Add Buddy")
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
                        let buddy = Buddy(
                            displayName: displayName,
                            contact: contact.isEmpty ? nil : contact
                        )
                        do {
                            try appState.diveService.saveBuddy(buddy)
                            dismiss()
                            onSave(buddy)
                        } catch {
                            print("Failed to save buddy: \(error)")
                        }
                    }
                    .disabled(displayName.isEmpty)
                }
            }
        }
    }
}
