import SwiftUI
import DivelogCore

struct DiveListView: View {
    @EnvironmentObject var appState: AppState
    @State private var dives: [Dive] = []
    @State private var selectedDive: Dive?
    @State private var searchText = ""
    @State private var filterCCROnly = false

    var filteredDives: [Dive] {
        dives.filter { dive in
            let matchesSearch = searchText.isEmpty ||
                String(dive.maxDepthM).contains(searchText)

            let matchesCCR = !filterCCROnly || dive.isCcr

            return matchesSearch && matchesCCR
        }
    }

    var body: some View {
        HSplitView {
            // Dive list
            VStack(spacing: 0) {
                // Toolbar
                HStack {
                    Toggle("CCR Only", isOn: $filterCCROnly)
                        .toggleStyle(.checkbox)

                    Spacer()

                    Button(action: { appState.showNewDiveSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                // List
                List(filteredDives, id: \.id, selection: $selectedDive) { dive in
                    DiveRowView(dive: dive)
                        .tag(dive)
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 300)

            // Detail view
            if let dive = selectedDive {
                DiveDetailView(dive: dive)
            } else {
                VStack {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a dive")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $searchText, prompt: "Search dives")
        .navigationTitle("Dives")
        .task {
            await loadDives()
        }
    }

    private func loadDives() async {
        do {
            let query = filterCCROnly ? DiveQuery.ccrOnly() : DiveQuery()
            dives = try appState.diveService.listDives(query: query)
        } catch {
            print("Failed to load dives: \(error)")
        }
    }
}

struct DiveRowView: View {
    let dive: Dive

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(formatDate(dive.startTimeUnix))
                    .font(.headline)

                Spacer()

                if dive.isCcr {
                    Text("CCR")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(4)
                }

                if dive.decoRequired {
                    Text("DECO")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .cornerRadius(4)
                }
            }

            HStack(spacing: 16) {
                Label(String(format: "%.1fm", dive.maxDepthM), systemImage: "arrow.down")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Label(formatDuration(dive.bottomTimeSec), systemImage: "timer")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if dive.cnsPercent > 0 {
                    Label(String(format: "%.0f%%", dive.cnsPercent), systemImage: "lungs")
                        .font(.subheadline)
                        .foregroundColor(dive.cnsPercent > 80 ? .orange : .secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDate(_ unix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: Int32) -> String {
        let minutes = seconds / 60
        return "\(minutes) min"
    }
}
