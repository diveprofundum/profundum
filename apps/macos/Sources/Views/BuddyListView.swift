import SwiftUI
import DivelogCore

struct BuddyListView: View {
    @EnvironmentObject var appState: AppState
    @State private var buddies: [Buddy] = []
    @State private var selectedBuddy: Buddy?
    @State private var showAddSheet = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("\(buddies.count) buddies")
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

                List(buddies, id: \.id, selection: $selectedBuddy) { buddy in
                    BuddyRowView(buddy: buddy)
                        .tag(buddy)
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 250)

            if let buddy = selectedBuddy {
                BuddyDetailView(buddy: buddy)
            } else {
                VStack {
                    Image(systemName: "person.2")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a buddy")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Buddies")
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
    }

    private func loadBuddies() async {
        do {
            buddies = try appState.diveService.listBuddies()
        } catch {
            print("Failed to load buddies: \(error)")
        }
    }
}

struct BuddyRowView: View {
    let buddy: Buddy

    var body: some View {
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

struct BuddyDetailView: View {
    let buddy: Buddy

    var body: some View {
        Form {
            Section("Buddy Information") {
                LabeledContent("Name", value: buddy.displayName)
                if let contact = buddy.contact, !contact.isEmpty {
                    LabeledContent("Contact", value: contact)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AddBuddySheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var displayName = ""
    @State private var contact = ""

    let onSave: (Buddy?) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Buddy")
                .font(.title2)

            Form {
                TextField("Name", text: $displayName)
                TextField("Contact (email/phone)", text: $contact)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                    onSave(nil)
                }
                .keyboardShortcut(.cancelAction)

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
                .keyboardShortcut(.defaultAction)
                .disabled(displayName.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
