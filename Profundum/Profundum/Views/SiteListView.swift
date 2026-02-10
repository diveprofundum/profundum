import SwiftUI
import DivelogCore

struct SiteListView: View {
    @EnvironmentObject var appState: AppState
    @State private var sites: [Site] = []
    @State private var showAddSheet = false
    @State private var siteToEdit: Site?

    var body: some View {
        List {
            ForEach(sites, id: \.id) { site in
                NavigationLink(destination: SiteDetailView(site: site, onEdit: {
                    siteToEdit = site
                })) {
                    SiteRowView(site: site)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteSite(site)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        siteToEdit = site
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
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
        .sheet(isPresented: $showAddSheet, onDismiss: {
            Task { await loadSites() }
        }) {
            AddSiteSheet()
        }
        .sheet(item: $siteToEdit, onDismiss: {
            Task { await loadSites() }
        }) { site in
            AddSiteSheet(editingSite: site)
        }
        .task {
            await loadSites()
        }
        .refreshable {
            await loadSites()
        }
    }

    private func loadSites() async {
        do {
            sites = try appState.diveService.listSites()
        } catch {
            print("Failed to load sites: \(error)")
        }
    }

    private func deleteSite(_ site: Site) {
        do {
            _ = try appState.diveService.deleteSite(id: site.id)
            sites.removeAll { $0.id == site.id }
        } catch {
            print("Failed to delete site: \(error)")
        }
    }
}

struct SiteRowView: View {
    let site: Site

    var body: some View {
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

struct SiteDetailView: View {
    let site: Site
    var onEdit: (() -> Void)?

    var body: some View {
        Form {
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

            if onEdit != nil {
                Section {
                    Button("Edit Site") {
                        onEdit?()
                    }
                }
            }
        }
        .formStyle(.grouped)
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

    var editingSite: Site?

    private var sheetTitle: String {
        editingSite != nil ? "Edit Site" : "Add Site"
    }

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
                        let site = Site(
                            id: editingSite?.id ?? UUID().uuidString,
                            name: name,
                            lat: Double(latitude),
                            lon: Double(longitude),
                            notes: notes.isEmpty ? nil : notes
                        )
                        do {
                            try appState.diveService.saveSite(site, tags: [])
                            dismiss()
                        } catch {
                            print("Failed to save site: \(error)")
                        }
                    }
                    .disabled(name.isEmpty)
                }
            }
            .onAppear {
                if let site = editingSite {
                    name = site.name
                    if let lat = site.lat { latitude = String(lat) }
                    if let lon = site.lon { longitude = String(lon) }
                    notes = site.notes ?? ""
                }
            }
        }
    }
}
