import SwiftUI
import DivelogCore

struct DiveListView: View {
    @EnvironmentObject var appState: AppState
    @State private var dives: [Dive] = []
    @State private var searchText = ""
    @State private var filterCCROnly = false
    @State private var showNewDiveSheet = false
    @State private var errorMessage: String?

    var filteredDives: [Dive] {
        dives.filter { dive in
            let matchesSearch = searchText.isEmpty ||
                String(dive.maxDepthM).contains(searchText)
            return matchesSearch
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredDives.isEmpty {
                    ContentUnavailableView {
                        Label("No Dives", systemImage: "waveform.path")
                    } description: {
                        Text("Add a dive or load sample data from Settings to get started.")
                    } actions: {
                        Button("Add Dive") {
                            showNewDiveSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(filteredDives, id: \.id) { dive in
                            NavigationLink(destination: DiveDetailView(dive: dive)) {
                                DiveRowView(dive: dive)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Dives")
            .searchable(text: $searchText, prompt: "Search dives")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("CCR Only", isOn: $filterCCROnly)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showNewDiveSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
                #else
                ToolbarItem {
                    Menu {
                        Toggle("CCR Only", isOn: $filterCCROnly)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }

                ToolbarItem {
                    Button(action: { showNewDiveSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
                #endif
            }
            .sheet(isPresented: $showNewDiveSheet) {
                NewDiveSheet()
            }
            .task {
                await loadDives()
            }
            .refreshable {
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
    }

    private func loadDives() async {
        errorMessage = nil

        do {
            let query = filterCCROnly ? DiveQuery.ccrOnly() : DiveQuery()
            dives = try appState.diveService.listDives(query: query)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DiveRowView: View {
    let dive: Dive

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(formatDate(dive.startTimeUnix))
                    .font(.headline)

                Spacer()

                if dive.isCcr {
                    Text("CCR")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }

                if dive.decoRequired {
                    Text("DECO")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .foregroundColor(.orange)
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
