import SwiftUI
import DivelogCore

struct SiteListView: View {
    @EnvironmentObject var appState: AppState
    @State private var sites: [Site] = []
    @State private var showAddSheet = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(sites, id: \.id) { site in
                    NavigationLink(destination: SiteDetailView(site: site)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(site.name)
                                .font(.headline)
                            if let lat = site.lat, let lon = site.lon {
                                Text(String(format: "%.4f, %.4f", lat, lon))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Sites")
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
                AddSiteSheet { site in
                    if let site = site {
                        sites.append(site)
                    }
                }
            }
            .task {
                await loadSites()
            }
            .refreshable {
                await loadSites()
            }
        }
    }

    private func loadSites() async {
        do {
            sites = try appState.diveService.listSites()
        } catch {
            print("Failed to load sites: \(error)")
        }
    }
}

struct SiteDetailView: View {
    let site: Site

    var body: some View {
        List {
            Section("Site Information") {
                LabeledContent("Name", value: site.name)
                if let lat = site.lat, let lon = site.lon {
                    LabeledContent("Latitude", value: String(format: "%.6f", lat))
                    LabeledContent("Longitude", value: String(format: "%.6f", lon))
                }
                if let notes = site.notes, !notes.isEmpty {
                    LabeledContent("Notes", value: notes)
                }
            }
        }
        .navigationTitle(site.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct AddSiteSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var name = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var notes = ""

    let onSave: (Site?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Latitude", text: $latitude)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    TextField("Longitude", text: $longitude)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Add Site")
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
                        let site = Site(
                            name: name,
                            lat: Double(latitude),
                            lon: Double(longitude),
                            notes: notes.isEmpty ? nil : notes
                        )
                        do {
                            try appState.diveService.saveSite(site, tags: [])
                            dismiss()
                            onSave(site)
                        } catch {
                            print("Failed to save site: \(error)")
                        }
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}
