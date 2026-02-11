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
    @State private var sourceCount: Int = 0
    @State private var sourceDeviceNames: [String] = []
    @State private var showSourceDevices = false
    @State private var surfaceIntervalSec: Int64?
    @State private var formulaResults: [(name: String, value: Double)] = []
    @State private var errorMessage: String?
    @State private var exportFileURL: URL?

    var onDiveUpdated: (() -> Void)?

    private var dive: Dive { diveWithSite.dive }

    private var predefinedTags: [PredefinedDiveTag] {
        tags.compactMap { PredefinedDiveTag(fromTag: $0) }
            .sorted { $0.category == .diveType && $1.category != .diveType }
    }

    private var customTags: [String] {
        tags.filter { PredefinedDiveTag(fromTag: $0) == nil }
    }

    private var hasPpo2Data: Bool {
        samples.contains { $0.ppo2_1 != nil || $0.ppo2_2 != nil || $0.ppo2_3 != nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection

                // Notes
                if let notes = dive.notes, !notes.isEmpty {
                    notesSection(notes)
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

                // Depth profile
                if !samples.isEmpty {
                    Divider()
                    depthProfileSection
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
        .navigationTitle(formatDate(dive.startTimeUnix))
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
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(formatDate(dive.startTimeUnix))
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
                    if sourceCount > 1 {
                        Button {
                            showSourceDevices = true
                        } label: {
                            Badge(text: "\(sourceCount) computers", color: .purple)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dive recorded by \(sourceCount) computers")
                        .popover(isPresented: $showSourceDevices) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Source Computers")
                                    .font(.headline)
                                    .padding(.bottom, 2)
                                ForEach(sourceDeviceNames, id: \.self) { name in
                                    HStack(spacing: 6) {
                                        Image(systemName: "cpu")
                                            .foregroundColor(.secondary)
                                        Text(name)
                                    }
                                }
                            }
                            .padding()
                            .frame(minWidth: 200)
                        }
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
            StatCard(title: "Bottom Time", value: "\(dive.bottomTimeSec / 60) min")
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

    private var depthProfileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Depth Profile")
                .font(.headline)

            DepthProfileChart(samples: samples, depthUnit: appState.depthUnit)
                .frame(height: 200)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(depthChartAccessibilityLabel)
        }
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
                }
            }
        }
    }

    private var depthChartAccessibilityLabel: String {
        let depthStr = UnitFormatter.formatDepth(dive.maxDepthM, unit: appState.depthUnit)
        let totalMinutes = (dive.endTimeUnix - dive.startTimeUnix) / 60
        return "Depth profile chart. Maximum depth \(depthStr) over \(totalMinutes) minutes."
    }

    private var ppo2ChartAccessibilityLabel: String {
        let data = PPO2ChartData(samples: samples)
        let sensorMode = data.hasPerSensorData ? "3 sensors" : "averaged"
        let maxValue = data.dataPoints.map(\.value).max() ?? 0
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

            PPO2Chart(samples: samples)
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

    private func formatDate(_ unix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        return DateFormatters.fullDateTime.string(from: date)
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

    private func gasMixLabel(_ mix: GasMix) -> String {
        let o2 = Int(mix.o2Fraction * 100)
        let he = Int(mix.heFraction * 100)
        if he > 0 {
            return "Tx \(o2)/\(he)"
        } else if o2 == 21 {
            return "Air"
        } else if o2 == 100 {
            return "O2"
        } else {
            return "Nx\(o2)"
        }
    }

    private func generateExport() {
        do {
            let exportService = ExportService(database: appState.database)
            let data = try exportService.exportDives(ids: [dive.id])
            let dateStr = formatDate(dive.startTimeUnix)
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

    private func loadDiveData() async {
        do {
            let detail = try appState.diveService.getDiveDetail(diveId: dive.id)
            samples = detail.samples
            tags = detail.tags
            gasMixes = detail.gasMixes
            loadedTeammateIds = detail.teammateIds
            loadedEquipmentIds = detail.equipmentIds
            sourceCount = Set(detail.sourceFingerprints.map(\.deviceId)).count
            sourceDeviceNames = detail.sourceDeviceNames

            let diveInput = DiveInput(
                startTimeUnix: dive.startTimeUnix,
                endTimeUnix: dive.endTimeUnix,
                bottomTimeSec: dive.bottomTimeSec
            )

            let sampleInputs = detail.samples.map { sample in
                SampleInput(
                    tSec: sample.tSec,
                    depthM: sample.depthM,
                    tempC: sample.tempC,
                    setpointPpo2: sample.setpointPpo2,
                    ceilingM: sample.ceilingM,
                    gf99: sample.gf99,
                    gasmixIndex: sample.gasmixIndex.map { Int32($0) }
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

    private var chartData: PPO2ChartData {
        PPO2ChartData(samples: samples)
    }

    private var colorScale: KeyValuePairs<String, Color> {
        if chartData.hasPerSensorData {
            return ["S1": .red, "S2": .green, "S3": .blue]
        } else {
            return ["PPO2": .cyan]
        }
    }

    private var selectedPoints: [PPO2DataPoint] {
        guard let selectedTime else { return [] }
        let data = chartData
        // Find the closest time
        guard let closestTime = data.dataPoints.min(by: {
            abs($0.timeMinutes - selectedTime) < abs($1.timeMinutes - selectedTime)
        })?.timeMinutes else {
            return []
        }
        return data.dataPoints.filter { abs($0.timeMinutes - closestTime) < 0.01 }
    }

    var body: some View {
        let data = chartData

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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
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
