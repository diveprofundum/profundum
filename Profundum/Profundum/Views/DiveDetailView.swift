import Charts
import DivelogCore
import SwiftUI

struct DiveDetailView: View {
    @EnvironmentObject var appState: AppState
    let diveWithSite: DiveWithSite
    @State private var samples: [DiveSample] = []
    @State private var tags: [String] = []
    @State private var gasMixes: [GasMix] = []
    @State private var stats: DiveStats?
    @State private var showEditSheet = false
    @State private var loadedTeammateIds: [String] = []
    @State private var loadedEquipmentIds: [String] = []
    @State private var sourceDeviceMap: [String: String] = [:]
    @State private var selectedDeviceId: String?
    @State private var hasPickedDevice = false
    @State private var surfaceIntervalSec: Int64?
    @State private var formulaResults: [(name: String, value: Double)] = []
    @State private var errorMessage: String?
    @State private var exportFileURL: URL?
    @State private var showFullscreenChart = false
    @State private var showTemperature = false
    @State private var showGf99 = false
    @State private var showAtPlusFive = false
    @State private var showDeltaFive = false
    @State private var showSurfGf = false
    @State private var showPpo2 = false
    @State private var showTankPressure = false
    @State private var splitDeviceId: String?
    @State private var showSplitConfirmation = false
    @State private var splitError: String?
    @State private var showBottomEndOverride = false
    @State private var currentDive: Dive?

    var onDiveUpdated: (() -> Void)?

    private var dive: Dive { currentDive ?? diveWithSite.dive }

    private var predefinedTags: [PredefinedDiveTag] {
        tags.compactMap { PredefinedDiveTag(fromTag: $0) }
            .sorted { ($0.category == .diveType ? 0 : 1) < ($1.category == .diveType ? 0 : 1) }
    }

    private var customTags: [String] {
        tags.filter { PredefinedDiveTag(fromTag: $0) == nil }
    }

    private var hasGf99Data: Bool {
        samples.contains { ($0.gf99 ?? 0) > 0 }
    }

    private var hasAtPlusFiveData: Bool {
        samples.contains { $0.atPlusFiveTtsMin != nil }
    }

    private var hasDeltaFiveData: Bool {
        samples.contains { $0.deltaFiveTtsMin != nil }
    }

    private var hasSurfGfData: Bool {
        samples.contains { $0.depthM > 3.0 }
    }

    private var hasPpo2Data: Bool {
        samples.contains { ($0.ppo2_1 ?? 0) > 0 }
    }

    private var hasTankPressureData: Bool {
        samples.contains { $0.tankPressure1Bar != nil || $0.tankPressure2Bar != nil }
    }

    /// Devices that actually have sample data for this dive.
    /// Filters out devices linked only via fingerprint (skipped dives).
    private var devicesWithSamples: [String: String] {
        let sampleDeviceIds = Set(samples.compactMap(\.deviceId))
        return sourceDeviceMap.filter { sampleDeviceIds.contains($0.key) }
    }

    /// Samples filtered to the selected device for chart display.
    private var chartSamples: [DiveSample] {
        guard let deviceId = selectedDeviceId else { return samples }
        let filtered = samples.filter { $0.deviceId == deviceId }
        return filtered.isEmpty ? samples : filtered
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection

                // Notes
                if let notes = dive.notes, !notes.isEmpty {
                    notesSection(notes)
                }

                // Depth profile (hero element)
                if !samples.isEmpty {
                    Divider()
                    depthProfileSection
                }

                Divider()

                statsSection

                // Deco / GF info
                if dive.decoModel != nil || dive.gfLow != nil || dive.endGf99 != nil {
                    Divider()
                    decoSection
                }

                // Advanced stats (from DiveStats)
                if stats != nil {
                    Divider()
                    advancedStatsSection
                }

                // User-defined formula results
                if !formulaResults.isEmpty {
                    Divider()
                    calculatedFieldsSection
                }

                // PPO2 chart for CCR dives
                if dive.isCcr && hasPpo2Data {
                    Divider()
                    ppo2Section
                }

                // CCR gas info
                if dive.isCcr {
                    Divider()
                    ccrSection
                }

                // Gas mixes
                if !gasMixes.isEmpty {
                    Divider()
                    gasMixSection
                }

                // Environment
                if dive.environment != nil || dive.visibility != nil || dive.weather != nil || dive.salinity != nil {
                    Divider()
                    environmentSection
                }

                // GPS
                if dive.lat != nil && dive.lon != nil {
                    Divider()
                    gpsSection
                }
            }
            .padding()
        }
        .navigationTitle(formatDate(dive.displayStartDate))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                if let exportFileURL {
                    ShareLink(item: exportFileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        generateExport()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    showEditSheet = true
                }
                .accessibilityIdentifier("editDiveButton")
            }
            #else
            ToolbarItem {
                if let exportFileURL {
                    ShareLink(item: exportFileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        generateExport()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem {
                Button("Edit") {
                    showEditSheet = true
                }
                .accessibilityIdentifier("editDiveButton")
            }
            #endif
        }
        .task(id: diveWithSite.id) {
            await loadDiveData()
        }
        .sheet(isPresented: $showEditSheet, onDismiss: {
            Task {
                await loadDiveData()
                onDiveUpdated?()
            }
        }) {
            NewDiveSheet(
                editingDive: dive,
                editingTags: tags,
                editingTeammateIds: loadedTeammateIds,
                editingEquipmentIds: loadedEquipmentIds
            )
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Split Dive",
            isPresented: $showSplitConfirmation,
            titleVisibility: .visible
        ) {
            Button("Split", role: .destructive) {
                performSplit()
            }
            Button("Cancel", role: .cancel) {
                splitDeviceId = nil
            }
        } message: {
            if let deviceId = splitDeviceId, let name = devicesWithSamples[deviceId] {
                Text("This will move \(name)'s samples into a separate dive."
                     + " Both dives will have their stats recomputed.")
            } else {
                Text("Split this device's data into a separate dive?")
            }
        }
        .alert("Split Failed", isPresented: Binding(
            get: { splitError != nil },
            set: { if !$0 { splitError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(splitError ?? "")
        }
        .sheet(isPresented: $showBottomEndOverride) {
            if let autoValue = stats?.bottomEndT, autoValue > 0 {
                BottomEndOverrideSheet(
                    dive: dive,
                    samples: samples,
                    autoBottomEndT: autoValue,
                    depthUnit: appState.depthUnit,
                    onSave: { newOverride in
                        saveBottomEndOverride(newOverride)
                    }
                )
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(formatDate(dive.displayStartDate))
                .font(.title2)

            if let siteName = diveWithSite.siteName {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundColor(.secondary)
                    Text(siteName)
                        .foregroundColor(.secondary)
                }
            }

            if let si = surfaceIntervalSec {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(.secondary)
                    Text("Surface Interval: \(formatSurfaceInterval(si))")
                        .foregroundColor(.secondary)
                }
            }

            // Tags row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if devicesWithSamples.count > 1 {
                        Menu {
                            Button {
                                selectedDeviceId = nil
                            } label: {
                                if selectedDeviceId == nil {
                                    Label("All Computers", systemImage: "checkmark")
                                } else {
                                    Text("All Computers")
                                }
                            }
                            Divider()
                            ForEach(
                                devicesWithSamples.sorted(by: { $0.value < $1.value }),
                                id: \.key
                            ) { deviceId, name in
                                Button {
                                    selectedDeviceId = deviceId
                                } label: {
                                    if deviceId == selectedDeviceId {
                                        Label(name, systemImage: "checkmark")
                                    } else {
                                        Text(name)
                                    }
                                }
                            }
                            Divider()
                            ForEach(
                                devicesWithSamples.sorted(by: { $0.value < $1.value }),
                                id: \.key
                            ) { deviceId, name in
                                Button(role: .destructive) {
                                    splitDeviceId = deviceId
                                    showSplitConfirmation = true
                                } label: {
                                    Label("Split \(name) into separate dive", systemImage: "arrow.branch")
                                }
                            }
                        } label: {
                            Badge(
                                text: "\(devicesWithSamples.count) computers",
                                color: .purple
                            )
                        }
                        .accessibilityLabel("Select source computer for chart")
                    }

                    ForEach(predefinedTags, id: \.self) { tag in
                        TagBadge(tag: tag)
                    }

                    ForEach(customTags, id: \.self) { tag in
                        CustomTagBadge(tag: tag)
                    }
                }
            }
        }
    }

    private var statsSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            StatCard(title: "Max Depth", value: UnitFormatter.formatDepth(dive.maxDepthM, unit: appState.depthUnit))
            StatCard(title: "Avg Depth", value: UnitFormatter.formatDepth(dive.avgDepthM, unit: appState.depthUnit))
            if dive.decoRequired {
                StatCard(title: "Bottom Time", value: "\((stats?.bottomTimeSec ?? dive.bottomTimeSec) / 60) min")
            }
            StatCard(title: "Total Time", value: formatTotalTime())

            if dive.cnsPercent > 0 {
                StatCard(title: "CNS", value: String(format: "%.0f%%", dive.cnsPercent),
                         color: dive.cnsPercent > 80 ? .orange : nil)
            }
            if dive.otu > 0 {
                StatCard(title: "OTU", value: String(format: "%.0f", dive.otu))
            }

            // Prefer dive model temps, fall back to computed stats
            if let minT = dive.minTempC {
                StatCard(
                    title: "Min Temp",
                    value: UnitFormatter.formatTemperature(
                        minT, unit: appState.temperatureUnit
                    )
                )
            } else if let stats = stats {
                StatCard(
                    title: "Min Temp",
                    value: UnitFormatter.formatTemperature(
                        stats.minTempC, unit: appState.temperatureUnit
                    )
                )
            }

            if let maxT = dive.maxTempC {
                StatCard(
                    title: "Max Temp",
                    value: UnitFormatter.formatTemperature(
                        maxT, unit: appState.temperatureUnit
                    )
                )
            } else if let stats = stats {
                StatCard(
                    title: "Max Temp",
                    value: UnitFormatter.formatTemperature(
                        stats.maxTempC, unit: appState.temperatureUnit
                    )
                )
            }

            if let avgT = dive.avgTempC {
                StatCard(
                    title: "Avg Temp",
                    value: UnitFormatter.formatTemperature(
                        avgT, unit: appState.temperatureUnit
                    )
                )
            }

        }
    }

    private var hasTemperatureVariation: Bool {
        let temps = samples.map(\.tempC)
        guard let lo = temps.min(), let hi = temps.max() else { return false }
        return hi - lo > 0.1
    }

    private var anyOverlayAvailable: Bool {
        hasTemperatureVariation || hasGf99Data || hasAtPlusFiveData || hasDeltaFiveData || hasSurfGfData
            || hasPpo2Data || hasTankPressureData
    }

    private var anyOverlayActive: Bool {
        showTemperature || showGf99 || showAtPlusFive || showDeltaFive || showSurfGf
            || showPpo2 || showTankPressure
    }

    private var depthProfileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Depth Profile")
                    .font(.headline)

                Spacer()

                if anyOverlayAvailable {
                    Menu {
                        if hasTemperatureVariation {
                            Toggle("Temperature", isOn: $showTemperature)
                        }
                        if hasGf99Data {
                            Toggle("GF99", isOn: $showGf99)
                        }
                        if hasAtPlusFiveData {
                            Toggle("@+5", isOn: $showAtPlusFive)
                        }
                        if hasDeltaFiveData {
                            Toggle("\u{0394}+5", isOn: $showDeltaFive)
                        }
                        if hasSurfGfData {
                            Toggle("SurfGF", isOn: $showSurfGf)
                        }
                        if hasPpo2Data {
                            Toggle("PPO2", isOn: $showPpo2)
                        }
                        if hasTankPressureData {
                            Toggle("Tank Pressure", isOn: $showTankPressure)
                        }
                    } label: {
                        Image(systemName: "square.3.layers.3d")
                            .font(.body)
                            .foregroundStyle(anyOverlayActive ? .primary : .secondary)
                    }
                    .accessibilityIdentifier("overlayMenu")
                }

                Button {
                    showFullscreenChart = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand depth profile fullscreen")
            }

            DepthProfileChart(
                samples: chartSamples,
                depthUnit: appState.depthUnit,
                temperatureUnit: appState.temperatureUnit,
                showTemperature: showTemperature,
                showGf99: showGf99,
                showAtPlusFive: showAtPlusFive,
                showDeltaFive: showDeltaFive,
                showSurfGf: showSurfGf,
                gasMixes: gasMixes,
                showPpo2: showPpo2,
                showTankPressure: showTankPressure,
                pressureUnit: appState.pressureUnit,
                bottomEndT: stats?.bottomEndT,
                decoStartT: stats?.decoStartT,
                isManualOverride: dive.bottomEndTOverrideSec != nil
            )
            .frame(height: 200)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
            )
            .accessibilityIdentifier("depthProfileChart")
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showFullscreenChart) {
            DepthProfileFullscreenView(
                samples: chartSamples,
                depthUnit: appState.depthUnit,
                temperatureUnit: appState.temperatureUnit,
                gasMixes: gasMixes,
                pressureUnit: appState.pressureUnit,
                bottomEndT: stats?.bottomEndT,
                decoStartT: stats?.decoStartT,
                isManualOverride: dive.bottomEndTOverrideSec != nil
            )
        }
        #else
        .sheet(isPresented: $showFullscreenChart) {
            DepthProfileFullscreenView(
                samples: chartSamples,
                depthUnit: appState.depthUnit,
                temperatureUnit: appState.temperatureUnit,
                gasMixes: gasMixes,
                pressureUnit: appState.pressureUnit,
                bottomEndT: stats?.bottomEndT,
                decoStartT: stats?.decoStartT,
                isManualOverride: dive.bottomEndTOverrideSec != nil
            )
            .frame(minWidth: 700, minHeight: 500)
        }
        #endif
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(notes)
                .font(.body)
                .foregroundColor(.primary)
        }
    }

    private var decoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Decompression")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                if let model = dive.decoModel {
                    StatCard(title: "Deco Model", value: model.capitalized)
                }
                if let gfLow = dive.gfLow, let gfHigh = dive.gfHigh {
                    StatCard(title: "GF Setting", value: "\(gfLow)/\(gfHigh)")
                }
                if let endGf = dive.endGf99 {
                    StatCard(title: "End GF99", value: String(format: "%.0f%%", endGf),
                             color: endGf > 85 ? .orange : nil)
                }
            }
        }
    }

    private var advancedStatsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Advanced Stats")
                .font(.headline)

            if let stats = stats {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    if stats.decoTimeSec > 0 {
                        StatCard(title: "Deco Time", value: "\(stats.decoTimeSec / 60) min")
                    }
                    if stats.descentRateMMin > 0 {
                        let descentVal = UnitFormatter.depth(
                            stats.descentRateMMin, unit: appState.depthUnit
                        )
                        let descentLabel = UnitFormatter.depthLabel(appState.depthUnit)
                        StatCard(
                            title: "Descent Rate",
                            value: String(format: "%.1f %@/min", descentVal, descentLabel)
                        )
                    }
                    if stats.ascentRateMMin > 0 {
                        let ascentVal = UnitFormatter.depth(
                            stats.ascentRateMMin, unit: appState.depthUnit
                        )
                        let ascentLabel = UnitFormatter.depthLabel(appState.depthUnit)
                        StatCard(
                            title: "Ascent Rate",
                            value: String(format: "%.1f %@/min", ascentVal, ascentLabel)
                        )
                    }
                    if stats.gasSwitchCount > 0 {
                        StatCard(title: "Gas Switches", value: "\(stats.gasSwitchCount)")
                    }
                    if stats.maxCeilingM > 0 {
                        StatCard(
                            title: "Max Ceiling",
                            value: UnitFormatter.formatDepth(
                                stats.maxCeilingM, unit: appState.depthUnit
                            )
                        )
                    }
                    if stats.maxGf99 > 0 {
                        StatCard(title: "Max GF99", value: String(format: "%.0f%%", stats.maxGf99),
                                 color: stats.maxGf99 > 85 ? .orange : nil)
                    }
                    if avgPpo2 > 0 {
                        StatCard(title: "Avg PPO2", value: String(format: "%.2f bar", avgPpo2))
                    }
                    if stats.bottomEndT > 0 {
                        Button {
                            showBottomEndOverride = true
                        } label: {
                            StatCard(
                                title: "Bottom End",
                                value: formatMinSec(stats.bottomEndT),
                                subtitle: dive.bottomEndTOverrideSec != nil ? "Manual" : nil
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Tap to override bottom end time")
                    }
                    if stats.decoStartT > 0 {
                        StatCard(title: "Deco Start", value: formatMinSec(stats.decoStartT))
                    }
                    if stats.ascentTimeSec > 0 {
                        StatCard(title: "Ascent Phase", value: "\(stats.ascentTimeSec / 60) min")
                    }
                }
            }
        }
    }

    private var ppo2ChartAccessibilityLabel: String {
        let hasPerSensor = samples.contains { $0.ppo2_2 != nil || $0.ppo2_3 != nil }
        let sensorMode = hasPerSensor ? "3 sensors" : "averaged"
        let maxValue = samples.compactMap(\.ppo2_1).max() ?? 0
        return "PPO2 sensor chart. \(sensorMode). Maximum PPO2 \(String(format: "%.2f", maxValue)) bar."
    }

    private var avgPpo2: Float {
        let values = samples.compactMap(\.setpointPpo2).filter { $0 > 0 }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    private var calculatedFieldsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calculated Fields")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ForEach(formulaResults, id: \.name) { result in
                    StatCard(title: result.name, value: String(format: "%.2f", result.value))
                }
            }
        }
    }

    private var ppo2Section: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PPO2 Sensors")
                .font(.headline)

            PPO2Chart(samples: chartSamples)
                .frame(height: 160)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ppo2ChartAccessibilityLabel)
        }
    }

    private var ccrSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CCR Information")
                .font(.headline)

            let hasO2Data = dive.o2RateCuftMin != nil
                || dive.o2RateLMin != nil
                || dive.o2ConsumedPsi != nil
                || dive.o2ConsumedBar != nil
            if hasO2Data {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 12) {
                    if let formatted = UnitFormatter.formatO2Rate(
                        cuftMin: dive.o2RateCuftMin,
                        lMin: dive.o2RateLMin,
                        unit: appState.pressureUnit
                    ) {
                        StatCard(title: "O2 Rate", value: formatted)
                    }
                    if let formatted = UnitFormatter.formatO2Consumed(
                        psi: dive.o2ConsumedPsi,
                        bar: dive.o2ConsumedBar,
                        unit: appState.pressureUnit
                    ) {
                        StatCard(title: "O2 Used", value: formatted)
                    }
                }
            } else {
                Text("No CCR gas data available for this dive.")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }
        }
    }

    private var gasMixSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gas Mixes")
                .font(.headline)

            ForEach(gasMixes) { mix in
                HStack {
                    Text(gasMixLabel(mix))
                        .font(.body)
                    Spacer()
                    if let usage = mix.usage, usage != "none" {
                        Text(usage.capitalized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Environment")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                if let env = dive.environment, !env.isEmpty {
                    StatCard(title: "Environment", value: env)
                }
                if let vis = dive.visibility, !vis.isEmpty {
                    StatCard(title: "Visibility", value: vis)
                }
                if let wtr = dive.weather, !wtr.isEmpty {
                    StatCard(title: "Weather", value: wtr)
                }
                if let sal = dive.salinity, !sal.isEmpty {
                    StatCard(title: "Water", value: sal.capitalized)
                }
            }
        }
    }

    private var gpsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Location")
                .font(.headline)

            if let lat = dive.lat, let lon = dive.lon {
                HStack(spacing: 4) {
                    Image(systemName: "location")
                        .foregroundColor(.secondary)
                    Text(String(format: "%.5f, %.5f", lat, lon))
                        .font(.body)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("GPS coordinates: \(String(format: "%.5f", lat)), \(String(format: "%.5f", lon))")
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        DateFormatters.fullDateTime(clock: appState.settings.clockFormat).string(from: date)
    }

    private func formatTotalTime() -> String {
        let total = dive.endTimeUnix - dive.startTimeUnix
        let minutes = total / 60
        return "\(minutes) min"
    }

    private func formatSurfaceInterval(_ seconds: Int64) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func formatMinSec(_ totalSec: Int32) -> String {
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%d:%02d", m, s)
    }

    private func gasMixLabel(_ mix: GasMix) -> String {
        DepthProfileChartData.gasLabel(o2: mix.o2Fraction, he: mix.heFraction)
    }

    private func generateExport() {
        do {
            let exportService = ExportService(database: appState.database)
            let data = try exportService.exportDives(ids: [dive.id])
            let dateStr = formatDate(dive.displayStartDate)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: " ", with: "_")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("dive-\(dateStr).json")
            try data.write(to: url)
            exportFileURL = url
        } catch {
            errorMessage = "Failed to export dive: \(error.localizedDescription)"
        }
    }

    private func performSplit() {
        guard let deviceId = splitDeviceId else { return }
        do {
            let importService = DiveComputerImportService(database: appState.database)
            _ = try importService.splitDive(diveId: dive.id, deviceId: deviceId)
            Task {
                await loadDiveData()
                onDiveUpdated?()
            }
        } catch {
            splitError = "Failed to split dive: \(error.localizedDescription)"
        }
        splitDeviceId = nil
    }

    private func saveBottomEndOverride(_ newOverride: Int32?) {
        do {
            var updated = dive
            updated.bottomEndTOverrideSec = newOverride
            try appState.diveService.saveDive(
                updated,
                tags: tags,
                teammateIds: loadedTeammateIds,
                equipmentIds: loadedEquipmentIds
            )
            currentDive = updated
            Task {
                await loadDiveData()
                onDiveUpdated?()
            }
        } catch {
            errorMessage = "Failed to save override: \(error.localizedDescription)"
        }
    }

    private func loadDiveData() async {
        do {
            let diveId = dive.id
            // Refresh dive from DB to pick up saved changes (e.g. override)
            currentDive = try appState.diveService.getDive(id: diveId)
            let detail = try appState.diveService.getDiveDetail(diveId: diveId)
            samples = detail.samples
            tags = detail.tags
            gasMixes = detail.gasMixes
            loadedTeammateIds = detail.teammateIds
            loadedEquipmentIds = detail.equipmentIds
            sourceDeviceMap = detail.sourceDeviceMap
            if !hasPickedDevice {
                selectedDeviceId = dive.deviceId
                hasPickedDevice = true
            }

            let diveInput = DiveInput(
                startTimeUnix: dive.startTimeUnix,
                endTimeUnix: dive.endTimeUnix,
                bottomTimeSec: dive.bottomTimeSec,
                isCcr: dive.isCcr,
                bottomEndTOverrideSec: dive.bottomEndTOverrideSec
            )

            let sampleInputs = detail.samples.map { sample in
                SampleInput(
                    tSec: sample.tSec,
                    depthM: sample.depthM,
                    tempC: sample.tempC,
                    setpointPpo2: sample.setpointPpo2,
                    ceilingM: sample.ceilingM,
                    gf99: sample.gf99,
                    gasmixIndex: sample.gasmixIndex.map { Int32($0) },
                    ppo2: sample.ppo2_1 ?? sample.setpointPpo2,
                    ttsSec: sample.ttsSec.map { Int32($0) },
                    ndlSec: sample.ndlSec.map { Int32($0) },
                    decoStopDepthM: sample.decoStopDepthM,
                    atPlusFiveTtsMin: sample.atPlusFiveTtsMin.map { Int32($0) }
                )
            }

            stats = DivelogCompute.computeDiveStats(dive: diveInput, samples: sampleInputs)

            // Compute surface interval
            surfaceIntervalSec = try appState.diveService.surfaceInterval(beforeDive: dive)

            // Compute user-defined formula results
            let formulas = try appState.diveService.listFormulas()
            if !formulas.isEmpty, let stats = stats {
                let variables = FormulaVariables.fromDive(dive, stats: stats)
                var results: [(name: String, value: Double)] = []
                for formula in formulas {
                    if let value = try? DivelogCompute.evaluateFormula(formula.expression, variables: variables) {
                        results.append((name: formula.name, value: value))
                    }
                }
                formulaResults = results
            }
        } catch {
            errorMessage = "Failed to load dive data: \(error.localizedDescription)"
        }
    }
}

// MARK: - PPO2 Chart

/// A single PPO2 data point for Swift Charts.
private struct PPO2DataPoint: Identifiable {
    let id = UUID()
    let timeMinutes: Float
    let value: Float
    let sensor: String
}

/// Pre-computed PPO2 chart data — single pass over samples.
private struct PPO2ChartData {
    let maxPpo2: Float
    let hasPerSensorData: Bool
    let dataPoints: [PPO2DataPoint]

    init(samples: [DiveSample]) {
        var maxP: Float = 0
        var hasPer = false
        var points: [PPO2DataPoint] = []

        for s in samples {
            let t = Float(s.tSec) / 60.0
            if let v = s.ppo2_1 {
                let sensorLabel = hasPer || s.ppo2_2 != nil || s.ppo2_3 != nil
                    ? "S1" : "PPO2"
                points.append(PPO2DataPoint(
                    timeMinutes: t, value: v, sensor: sensorLabel
                ))
                if v > maxP { maxP = v }
            }
            if let v = s.ppo2_2 {
                points.append(PPO2DataPoint(timeMinutes: t, value: v, sensor: "S2"))
                if v > maxP { maxP = v }
                hasPer = true
            }
            if let v = s.ppo2_3 {
                points.append(PPO2DataPoint(timeMinutes: t, value: v, sensor: "S3"))
                if v > maxP { maxP = v }
                hasPer = true
            }
        }

        // Fix sensor names if we detected per-sensor data
        if hasPer {
            self.dataPoints = points.map { pt in
                if pt.sensor == "PPO2" {
                    return PPO2DataPoint(timeMinutes: pt.timeMinutes, value: pt.value, sensor: "S1")
                }
                return pt
            }
        } else {
            self.dataPoints = points
        }

        self.maxPpo2 = max(maxP * 1.1, 1.6)
        self.hasPerSensorData = hasPer
    }
}

struct PPO2Chart: View {
    let samples: [DiveSample]

    @State private var selectedTime: Float?
    @State private var chartData: PPO2ChartData?

    private var colorScale: KeyValuePairs<String, Color> {
        if chartData?.hasPerSensorData == true {
            return ["S1": .red, "S2": .green, "S3": .blue]
        } else {
            return ["PPO2": .cyan]
        }
    }

    private var selectedPoints: [PPO2DataPoint] {
        guard let selectedTime, let data = chartData else { return [] }
        // Find the closest time
        guard let closestTime = data.dataPoints.min(by: {
            abs($0.timeMinutes - selectedTime) < abs($1.timeMinutes - selectedTime)
        })?.timeMinutes else {
            return []
        }
        return data.dataPoints.filter { abs($0.timeMinutes - closestTime) < 0.01 }
    }

    var body: some View {
        Group {
        if let data = chartData {
        Chart {
            ForEach(data.dataPoints) { point in
                LineMark(
                    x: .value("Time", point.timeMinutes),
                    y: .value("PPO2", point.value)
                )
                .foregroundStyle(by: .value("Sensor", point.sensor))
                .lineStyle(StrokeStyle(lineWidth: data.hasPerSensorData ? 1.5 : 2))
            }

            // Warning line at 1.6 bar
            RuleMark(y: .value("Warning", Float(1.6)))
                .foregroundStyle(Color.orange.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            if let selectedTime, let closestPoint = selectedPoints.first {
                RuleMark(x: .value("Selected", closestPoint.timeMinutes))
                    .foregroundStyle(Color.gray.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, spacing: 4) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(selectedPoints) { pt in
                                Text("\(pt.sensor): \(String(format: "%.2f", pt.value)) bar")
                                    .font(.caption2)
                            }
                        }
                        .padding(4)
                        .background(tooltipBackground)
                        .cornerRadius(4)
                    }
            }
        }
        .chartForegroundStyleScale(colorScale)
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let minutes = value.as(Float.self) {
                        Text("\(Int(minutes))m")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let ppo2 = value.as(Float.self) {
                        Text(String(format: "%.1f", ppo2))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let origin = geometry[proxy.plotAreaFrame].origin
                                let x = value.location.x - origin.x
                                if let time: Float = proxy.value(atX: x) {
                                    selectedTime = time
                                }
                            }
                            .onEnded { _ in
                                selectedTime = nil
                            }
                    )
            }
        }
        .padding(.leading, 4)
        } else {
            Color.clear
        }
        }
        .onAppear {
            chartData = PPO2ChartData(samples: samples)
        }
        .onChange(of: samples.cacheKey) { _, _ in
            chartData = PPO2ChartData(samples: samples)
        }
    }

    private var tooltipBackground: some ShapeStyle {
        #if os(iOS)
        Color(.systemBackground).opacity(0.9)
        #else
        Color(.windowBackgroundColor).opacity(0.9)
        #endif
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(6)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var color: Color?
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
            }
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
        .accessibilityElement(children: .combine)
    }
}
