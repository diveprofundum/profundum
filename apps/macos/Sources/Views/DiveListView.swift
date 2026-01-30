import SwiftUI
import DivelogCore

struct DiveListView: View {
    @EnvironmentObject var appState: AppState
    @State private var dives: [Dive] = []
    @State private var selectedDive: Dive?
    @State private var searchText = ""
    @State private var filterCCROnly = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var filteredDives: [Dive] {
        dives.filter { dive in
            let matchesSearch = searchText.isEmpty ||
                String(dive.maxDepthM).contains(searchText)

            return matchesSearch
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

                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    }

                    Button(action: { Task { await loadDives() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")

                    Button(action: { appState.showNewDiveSheet = true }) {
                        Image(systemName: "plus")
                    }
                    .help("New Dive")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                // List or empty state
                if filteredDives.isEmpty && !isLoading {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.path")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No dives yet")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Add a dive or load sample data to get started.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List(filteredDives, id: \.id, selection: $selectedDive) { dive in
                        DiveRowView(dive: dive)
                            .tag(dive)
                    }
                    .listStyle(.inset)
                }
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
        .onChange(of: filterCCROnly) { _, _ in
            Task { await loadDives() }
        }
        .alert("Error Loading Dives", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Retry") {
                Task { await loadDives() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private func loadDives() async {
        isLoading = true
        errorMessage = nil

        do {
            let query = filterCCROnly ? DiveQuery.ccrOnly() : DiveQuery()
            dives = try appState.diveService.listDives(query: query)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
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
