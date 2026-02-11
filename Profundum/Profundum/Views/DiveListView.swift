import DivelogCore
import SwiftUI

struct DiveListView: View {
    @EnvironmentObject var appState: AppState
    @State private var dives: [DiveWithSite] = []
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var selectedTypeFilters: Set<DiveTypeFilter> = []
    @State private var selectedTags: Set<PredefinedDiveTag> = []
    @State private var filterStartDate: Date?
    @State private var filterEndDate: Date?
    @State private var showDateFilter = false
    @State private var showNewDiveSheet = false
    @State private var errorMessage: String?
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    @State private var selectedDiveIDs: Set<String> = []
    @State private var showDeleteConfirmation = false
    @State private var batchExportURL: URL?
    @State private var showBatchShareSheet = false
    #endif
    @State private var hasMoreDives = true
    @State private var isLoadingMore = false

    var filteredDives: [DiveWithSite] {
        dives.filter { diveWithSite in
            let dive = diveWithSite.dive

            let matchesSearch = debouncedSearchText.isEmpty ||
                String(dive.maxDepthM).contains(debouncedSearchText) ||
                (diveWithSite.siteName?.localizedCaseInsensitiveContains(debouncedSearchText) ?? false)

            let matchesType = selectedTypeFilters.isEmpty ||
                selectedTypeFilters.contains { $0.matches(dive: dive) }

            return matchesSearch && matchesType
        }
    }

    private var hasActiveFilters: Bool {
        !selectedTypeFilters.isEmpty || !selectedTags.isEmpty || filterStartDate != nil || filterEndDate != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredDives.isEmpty {
                    ContentUnavailableView {
                        Label(
                            hasActiveFilters ? "No Matching Dives" : "No Dives",
                            systemImage: "waveform.path"
                        )
                    } description: {
                        Text(
                            hasActiveFilters
                                ? "Try adjusting your filters."
                                : "Add a dive or load sample data from Settings to get started."
                        )
                    } actions: {
                        if !hasActiveFilters {
                            Button("Add Dive") {
                                showNewDiveSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Clear Filters") {
                                clearFilters()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    diveList
                }
            }
            .navigationTitle("Dives")
            .searchable(text: $searchText, prompt: "Search dives")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    if editMode == .active {
                        HStack(spacing: 16) {
                            Button("Select All") {
                                selectedDiveIDs = Set(filteredDives.map(\.id))
                            }
                            if !selectedDiveIDs.isEmpty {
                                Button {
                                    generateBatchExport()
                                } label: {
                                    Label("Export \(selectedDiveIDs.count)", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete \(selectedDiveIDs.count)", systemImage: "trash")
                                }
                            }
                        }
                    } else {
                        DateFilterButton(
                            startDate: $filterStartDate,
                            endDate: $filterEndDate,
                            showPopover: $showDateFilter
                        ) {
                            Task { await loadDives() }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if editMode == .active {
                        Button("Done") {
                            exitEditMode()
                        }
                    } else {
                        Menu {
                            Button(action: { showNewDiveSheet = true }) {
                                Label("Add Dive", systemImage: "plus")
                            }
                            Button(action: {
                                editMode = .active
                            }) {
                                Label("Select Dives", systemImage: "checkmark.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                #else
                ToolbarItem(placement: .automatic) {
                    DateFilterButton(
                        startDate: $filterStartDate,
                        endDate: $filterEndDate,
                        showPopover: $showDateFilter
                    ) {
                        Task { await loadDives() }
                    }
                }
                ToolbarItem {
                    Button(action: { showNewDiveSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
                #endif
            }
            #if os(iOS)
            .confirmationDialog(
                "Delete \(selectedDiveIDs.count) Dive\(selectedDiveIDs.count == 1 ? "" : "s")?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    deleteSelectedDives()
                }
            } message: {
                Text("This action cannot be undone.")
            }
            .sheet(isPresented: $showBatchShareSheet, onDismiss: {
                exitEditMode()
            }) {
                if let batchExportURL {
                    ActivityViewController(activityItems: [batchExportURL])
                }
            }
            #endif
            .safeAreaInset(edge: .top) {
                filterBar
            }
            .sheet(isPresented: $showNewDiveSheet, onDismiss: {
                Task { await loadDives() }
            }) {
                NewDiveSheet()
            }
            .task {
                await loadDives()
            }
            .refreshable {
                await loadDives()
            }
            .onChange(of: searchText) { _, newValue in
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    debouncedSearchText = newValue
                }
            }
            .onChange(of: selectedTags) { _, _ in
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

    private var diveListContent: some View {
        Group {
            ForEach(filteredDives, id: \.id) { diveWithSite in
                NavigationLink(destination: DiveDetailView(diveWithSite: diveWithSite, onDiveUpdated: {
                    Task { await loadDives() }
                })) {
                    DiveRowView(diveWithSite: diveWithSite)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        deleteDive(diveWithSite)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            if hasMoreDives {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
                    .onAppear {
                        Task { await loadMoreDives() }
                    }
            }
        }
    }

    private var diveList: some View {
        #if os(iOS)
        List(selection: $selectedDiveIDs) {
            diveListContent
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        #else
        List {
            diveListContent
        }
        .listStyle(.plain)
        #endif
    }

    private var filterBar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DiveTypeFilter.allCases, id: \.self) { filter in
                        DiveTypeChipView(
                            filter: filter,
                            isSelected: selectedTypeFilters.contains(filter)
                        ) {
                            toggleTypeFilter(filter)
                        }
                    }

                    Divider()
                        .frame(height: 20)

                    ForEach(PredefinedDiveTag.activityCases, id: \.self) { tag in
                        TagChipView(
                            tag: tag,
                            isSelected: selectedTags.contains(tag)
                        ) {
                            toggleTag(tag)
                        }
                    }

                    if hasActiveFilters {
                        Button("Clear") {
                            clearFilters()
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
            .background(.bar)

            Divider()
        }
    }

    private func toggleTypeFilter(_ filter: DiveTypeFilter) {
        if selectedTypeFilters.contains(filter) {
            selectedTypeFilters.remove(filter)
        } else {
            selectedTypeFilters.insert(filter)
        }
    }

    private func toggleTag(_ tag: PredefinedDiveTag) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    private func clearFilters() {
        selectedTypeFilters.removeAll()
        selectedTags.removeAll()
        filterStartDate = nil
        filterEndDate = nil
        Task { await loadDives() }
    }

    private func buildQuery() -> DiveQuery {
        var query = DiveQuery()

        if !selectedTags.isEmpty {
            query.tagAny = selectedTags.map { $0.rawValue }
        }

        if let startDate = filterStartDate {
            query.startTimeMin = Int64(startDate.timeIntervalSince1970)
        }
        if let endDate = filterEndDate {
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: endDate) ?? endDate
            query.startTimeMax = Int64(endOfDay.timeIntervalSince1970)
        }

        return query
    }

    private func loadDives() async {
        errorMessage = nil

        do {
            let query = buildQuery()
            let result = try appState.diveService.listDivesWithSites(query: query)
            dives = result
            hasMoreDives = result.count == (query.limit ?? 50)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMoreDives() async {
        guard !isLoadingMore, hasMoreDives else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            var query = buildQuery()
            query.offset = dives.count
            let result = try appState.diveService.listDivesWithSites(query: query)
            dives.append(contentsOf: result)
            hasMoreDives = result.count == (query.limit ?? 50)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if os(iOS)
    private func generateBatchExport() {
        do {
            let exportService = ExportService(database: appState.database)
            let data = try exportService.exportDives(ids: Array(selectedDiveIDs))
            let filename = "divelog-export-\(selectedDiveIDs.count)-dives.json"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename)
            try data.write(to: url)
            batchExportURL = url
            showBatchShareSheet = true
        } catch {
            errorMessage = "Failed to export dives: \(error.localizedDescription)"
        }
    }

    private func exitEditMode() {
        editMode = .inactive
        selectedDiveIDs.removeAll()
        batchExportURL = nil
        showBatchShareSheet = false
    }
    #endif

    private func deleteDive(_ diveWithSite: DiveWithSite) {
        do {
            _ = try appState.diveService.deleteDive(id: diveWithSite.dive.id)
            dives.removeAll { $0.id == diveWithSite.id }
        } catch {
            errorMessage = "Failed to delete dive: \(error.localizedDescription)"
        }
    }

    #if os(iOS)
    private func deleteSelectedDives() {
        var failCount = 0
        for id in selectedDiveIDs {
            do {
                _ = try appState.diveService.deleteDive(id: id)
            } catch {
                failCount += 1
            }
        }
        dives.removeAll { selectedDiveIDs.contains($0.id) }
        selectedDiveIDs.removeAll()
        editMode = .inactive
        if failCount > 0 {
            errorMessage = "Failed to delete \(failCount) dive\(failCount == 1 ? "" : "s")."
        }
    }
    #endif
}

struct DiveRowView: View {
    @EnvironmentObject var appState: AppState
    let diveWithSite: DiveWithSite

    private var dive: Dive { diveWithSite.dive }

    /// Badges for notable dive properties shown in the list row.
    /// OC Rec is the default and doesn't need a badge.
    private var rowBadges: [(text: String, color: Color)] {
        var badges: [(String, Color)] = []
        if dive.isCcr {
            badges.append(("CCR", .blue))
        }
        if dive.decoRequired {
            badges.append(("Deco", .orange))
        }
        return badges
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatDate(dive.startTimeUnix))
                        .font(.headline)

                    if let siteName = diveWithSite.siteName {
                        Text(siteName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                ForEach(rowBadges, id: \.text) { badge in
                    Text(badge.text)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badge.color.opacity(0.2))
                        .foregroundColor(badge.color)
                        .cornerRadius(4)
                }
            }

            HStack(spacing: 16) {
                Label(
                    UnitFormatter.formatDepthCompact(
                        dive.maxDepthM, unit: appState.depthUnit
                    ),
                    systemImage: "arrow.down"
                )
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    private var rowAccessibilityLabel: String {
        let dateStr = formatDate(dive.startTimeUnix)
        let depthStr = UnitFormatter.formatDepthCompact(dive.maxDepthM, unit: appState.depthUnit)
        let durationStr = formatDuration(dive.bottomTimeSec)
        var label = "Dive on \(dateStr), \(depthStr), \(durationStr)"
        if let siteName = diveWithSite.siteName {
            label = "Dive on \(dateStr), \(siteName), \(depthStr), \(durationStr)"
        }
        if !rowBadges.isEmpty {
            label += ", " + rowBadges.map(\.text).joined(separator: ", ")
        }
        return label
    }

    private func formatDate(_ unix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        return DateFormatters.mediumDateTime.string(from: date)
    }

    private func formatDuration(_ seconds: Int32) -> String {
        let minutes = seconds / 60
        return "\(minutes) min"
    }
}

#if os(iOS)
struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
