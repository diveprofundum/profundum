import SwiftUI
import DivelogCore

struct SiteListView: View {
    @EnvironmentObject var appState: AppState
    @State private var sites: [Site] = []
    @State private var selectedSite: Site?
    @State private var showAddSheet = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("\(sites.count) sites")
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

                List(sites, id: \.id, selection: $selectedSite) { site in
                    SiteRowView(site: site)
                        .tag(site)
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 250)

            if let site = selectedSite {
                SiteDetailView(site: site)
            } else {
                VStack {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a site")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Sites")
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
    }

    private func loadSites() async {
        do {
            sites = try appState.diveService.listSites()
        } catch {
            print("Failed to load sites: \(error)")
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
        }
        .formStyle(.grouped)
        .padding()
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
        VStack(spacing: 20) {
            Text("Add Site")
                .font(.title2)

            Form {
                TextField("Name", text: $name)
                TextField("Latitude", text: $latitude)
                TextField("Longitude", text: $longitude)
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
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
