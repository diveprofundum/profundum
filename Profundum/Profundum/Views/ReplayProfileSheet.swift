import DivelogCore
import SwiftUI

struct ReplayProfileSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let dive: Dive
    let gasMixes: [GasMix]
    let stats: DiveStats?
    let samples: [DiveSample]

    // MARK: - Mode

    enum ReplayMode: String, CaseIterable {
        case actualDive = "Actual Dive"
        case whatIfPlanning = "What-If Planning"
    }

    @State private var replayMode: ReplayMode = .actualDive

    // MARK: - Form state

    @State private var targetDepthText: String = ""
    @State private var bottomTimeMinutes: Int = 20
    @State private var descentRateText: String = ""
    @State private var ascentRateText: String = ""
    @State private var selectedModel: DecoModel = .buhlmannZhl16c
    @State private var thalmannPdcs: ThalmannPdcs = .pdcs23
    @State private var gfLow: Int = 30
    @State private var gfHigh: Int = 70
    @State private var gfLowText: String = "30"
    @State private var gfHighText: String = "70"
    @State private var gasPlanEntries: [GasPlanEntry] = []
    @State private var diluentO2Percent: Int = 21
    @State private var diluentHePercent: Int = 35
    @State private var setpointText: String = "1.3"
    @State private var originalSetpointText: String = ""
    @State private var originalDiluentO2: Int = 21
    @State private var originalDiluentHe: Int = 35
    @FocusState private var focusedField: Bool
    @State private var surfacePressureText: String = "1.01325"
    @State private var tempText: String = ""
    @State private var lastStopDepthText: String = ""
    @State private var stopIntervalText: String = ""

    // MARK: - Result state

    enum ReplayResult {
        case synthetic(ProfileGenResult)
        /// Actual-dive result: overlay (full profile) + planned stops (from bottom-end)
        case actual(overlay: DecoSimResult, planned: DecoSimResult)
    }

    @State private var result: ReplayResult?
    @State private var errorMessage: String?
    @State private var isGenerating = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modePicker
                    if replayMode == .whatIfPlanning {
                        depthAndTimeSection
                    }
                    decoModelSection
                    if selectedModel == .buhlmannZhl16c {
                        gradientFactorsSection
                    } else {
                        thalmannConservatismSection
                    }
                    if dive.isCcr {
                        ccrDiluentSection
                    } else if replayMode == .whatIfPlanning {
                        gasPlanSection
                    }
                    advancedSection
                    generateButton
                    if let errorMessage {
                        errorBanner(errorMessage)
                    }
                    if let result {
                        resultSummary(result)
                    }
                }
                .padding()
            }
            .navigationTitle("Replay Profile")
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            #endif
        }
        .onAppear { prefill() }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
        #endif
    }

    // MARK: - Sections

    private var depthAndTimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Depth & Time")
                .font(.headline)
            HStack {
                TextField("Target depth", text: $targetDepthText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                    .focused($focusedField)
                    .accessibilityLabel("Target depth in \(depthLabel)")
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text(depthLabel)
                    .foregroundColor(.secondary)
            }
            Stepper("Bottom time: \(bottomTimeMinutes) min", value: $bottomTimeMinutes, in: 1...600)
                .accessibilityLabel("Bottom time \(bottomTimeMinutes) minutes")
            HStack {
                TextField("Descent rate", text: $descentRateText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                    .focused($focusedField)
                    .accessibilityLabel("Descent rate in \(depthLabel) per minute")
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text("\(depthLabel)/min descent")
                    .foregroundColor(.secondary)
            }
            HStack {
                TextField("Ascent rate", text: $ascentRateText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                    .focused($focusedField)
                    .accessibilityLabel("Ascent rate in \(depthLabel) per minute")
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text("\(depthLabel)/min ascent")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var decoModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Deco Model")
                .font(.headline)
            Picker("Model", selection: $selectedModel) {
                Text("Bühlmann ZHL-16C").tag(DecoModel.buhlmannZhl16c)
                Text("Thalmann EL-DCA").tag(DecoModel.thalmannElDca)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Decompression model")
        }
    }

    private var gradientFactorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gradient Factors")
                .font(.headline)
            HStack {
                Text("GF Low:")
                TextField("GF Low", text: $gfLowText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 60)
                    .focused($focusedField)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .onChange(of: gfLowText) { _, newVal in
                        if let v = Int(newVal), (1...100).contains(v), gfLow != v { gfLow = v }
                    }
                Stepper("", value: $gfLow, in: 1...100)
                    .labelsHidden()
                    .onChange(of: gfLow) { _, newVal in
                        let s = "\(newVal)"
                        if gfLowText != s { gfLowText = s }
                    }
            }
            .accessibilityLabel("Gradient factor low \(gfLow)")
            HStack {
                Text("GF High:")
                TextField("GF High", text: $gfHighText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 60)
                    .focused($focusedField)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .onChange(of: gfHighText) { _, newVal in
                        if let v = Int(newVal), (1...100).contains(v), gfHigh != v { gfHigh = v }
                    }
                Stepper("", value: $gfHigh, in: 1...100)
                    .labelsHidden()
                    .onChange(of: gfHigh) { _, newVal in
                        let s = "\(newVal)"
                        if gfHighText != s { gfHighText = s }
                    }
            }
            .accessibilityLabel("Gradient factor high \(gfHigh)")
        }
    }

    private var thalmannConservatismSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DCS Risk Target")
                .font(.headline)
            Picker("P_DCS", selection: $thalmannPdcs) {
                Text("2.3%").tag(ThalmannPdcs.pdcs23)
                Text("4.0%").tag(ThalmannPdcs.pdcs40)
                Text("5.0%").tag(ThalmannPdcs.pdcs50)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Target probability of DCS")
            Text("XVal-He-9 parameter sets from NEDU TR 18-05. Lower is more conservative.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var gasPlanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gas Plan")
                .font(.headline)
            ForEach(Array(gasPlanEntries.enumerated()), id: \.element.id) { index, entry in
                gasPlanRow(index: index, entry: entry)
                    .accessibilityElement(children: .combine)
            }
            if gasPlanEntries.count < 5 {
                Button {
                    gasPlanEntries.append(GasPlanEntry(o2Percent: 50, hePercent: 0, switchDepthText: "21"))
                } label: {
                    Label("Add Gas", systemImage: "plus.circle")
                }
                .accessibilityLabel("Add deco gas")
            }
        }
    }

    private func gasPlanRow(index: Int, entry: GasPlanEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(index == 0 ? "Bottom Gas" : "Deco Gas \(index)")
                    .font(.subheadline.bold())
                Spacer()
                if index > 0 {
                    Button(role: .destructive) {
                        gasPlanEntries.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Remove gas \(index)")
                }
            }
            HStack(spacing: 12) {
                Stepper("O₂: \(gasPlanEntries[index].o2Percent)%",
                        value: $gasPlanEntries[index].o2Percent, in: 5...100)
                    .frame(maxWidth: 200)
            }
            HStack(spacing: 12) {
                Stepper("He: \(gasPlanEntries[index].hePercent)%",
                        value: $gasPlanEntries[index].hePercent,
                        in: 0...(100 - gasPlanEntries[index].o2Percent))
                    .frame(maxWidth: 200)
            }
            if index > 0 {
                HStack {
                    TextField("Switch depth", text: $gasPlanEntries[index].switchDepthText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                        .focused($focusedField)
                        .accessibilityLabel("Switch depth in \(depthLabel)")
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Text(depthLabel)
                        .foregroundColor(.secondary)
                }
            }
            Text(gasLabel(o2: gasPlanEntries[index].o2Percent, he: gasPlanEntries[index].hePercent))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }

    private var ccrDiluentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diluent & Setpoint")
                .font(.headline)

            // Diluent card
            VStack(alignment: .leading, spacing: 4) {
                Text("Diluent").font(.subheadline.bold())
                Stepper("O₂: \(diluentO2Percent)%",
                        value: $diluentO2Percent, in: 5...100)
                    .frame(maxWidth: 200)
                Stepper("He: \(diluentHePercent)%",
                        value: $diluentHePercent,
                        in: 0...(100 - diluentO2Percent))
                    .frame(maxWidth: 200)
                Text(gasLabel(o2: diluentO2Percent, he: diluentHePercent))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)

            // Setpoint
            HStack {
                TextField("Setpoint", text: $setpointText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 80)
                    .focused($focusedField)
                    .accessibilityLabel("CCR setpoint in bar")
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text("bar")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Surface pressure", text: $surfacePressureText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                        .focused($focusedField)
                        .accessibilityLabel("Surface pressure in bar")
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Text("bar")
                        .foregroundColor(.secondary)
                }
                HStack {
                    TextField("Temperature", text: $tempText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                        .focused($focusedField)
                        .accessibilityLabel("Water temperature in \(tempLabel)")
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Text(tempLabel)
                        .foregroundColor(.secondary)
                }
                HStack {
                    TextField("Last stop depth", text: $lastStopDepthText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                        .focused($focusedField)
                        .accessibilityLabel("Last stop depth in \(depthLabel)")
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Text(depthLabel)
                        .foregroundColor(.secondary)
                }
                HStack {
                    TextField("Stop interval", text: $stopIntervalText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                        .focused($focusedField)
                        .accessibilityLabel("Deco stop interval in \(depthLabel)")
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Text(depthLabel)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: $replayMode) {
                ForEach(ReplayMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(samples.isEmpty)
            .accessibilityLabel("Replay mode")

            if replayMode == .actualDive {
                Text("Runs the deco algorithm on your actual recorded dive profile.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Generates a synthetic square profile from the parameters below.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var generateButton: some View {
        Button {
            generate()
        } label: {
            HStack {
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(replayMode == .actualDive ? "Compute Deco Analysis" : "Generate Profile")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isGenerating)
        .accessibilityLabel(replayMode == .actualDive ? "Compute deco analysis" : "Generate dive profile")
        .accessibilityHint("Runs the decompression simulation with current parameters")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
            Text(message)
                .font(.callout)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
        .accessibilityLabel("Error: \(message)")
    }

    @ViewBuilder
    private func resultSummary(_ result: ReplayResult) -> some View {
        let extracted = extractResultData(result)
        let isActual = if case .actual = result { true } else { false }

        // Chart section
        let chartData: ReplayChartData = {
            switch result {
            case .synthetic(let profileResult):
                return ReplayChartData(result: profileResult, depthUnit: appState.depthUnit)
            case .actual(let overlay, let planned):
                return ReplayChartData(
                    samples: samples,
                    decoResult: overlay,
                    plannedStops: planned.decoStops,
                    gasMixes: gasMixes,
                    depthUnit: appState.depthUnit
                )
            }
        }()

        let sampleInputs: [SampleInput] = {
            switch result {
            case .synthetic(let profileResult):
                return profileResult.samples
            case .actual:
                return samples.toSampleInputs()
            }
        }()

        ReplayChartSection(
            chartData: chartData,
            samples: sampleInputs,
            depthUnit: appState.depthUnit
        )

        resultGrid(
            decoResult: extracted.decoResult,
            totalTimeSec: extracted.totalTimeSec,
            decoTimeSec: extracted.decoTimeSec,
            isActualDive: isActual
        )
    }

    // swiftlint:disable:next line_length
    private func extractResultData(_ result: ReplayResult) -> (decoResult: DecoSimResult, totalTimeSec: Int32, decoTimeSec: Int32) {
        switch result {
        case .synthetic(let profileResult):
            return (
                profileResult.decoResult,
                profileResult.totalTimeSec,
                profileResult.totalTimeSec - profileResult.bottomEndTSec
            )
        case .actual(let overlay, let planned):
            let totalTime = samples.last.map { $0.tSec } ?? 0
            return (overlay, totalTime, planned.totalDecoTimeSec)
        }
    }

    // swiftlint:disable:next line_length
    private func resultGrid(decoResult: DecoSimResult, totalTimeSec: Int32, decoTimeSec: Int32, isActualDive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Result")
                .font(.headline)

            if decoResult.truncated {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Profile was truncated — results may exceed safe limits with these parameters.")
                        .font(.callout)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
                .accessibilityLabel("Warning: profile was truncated due to parameter limits")
            }

            let columns = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: 12) {
                StatCard(
                    title: isActualDive ? "Recorded Time" : "Total Time",
                    value: "\(totalTimeSec / 60) min"
                )
                StatCard(
                    title: "Deco Stop Time",
                    value: "\(decoTimeSec / 60) min"
                )
                StatCard(
                    title: "Max Ceiling",
                    value: UnitFormatter.formatDepth(
                        decoResult.maxCeilingM,
                        unit: appState.depthUnit
                    )
                )
                StatCard(
                    title: "Max GF99",
                    value: String(format: "%.0f%%", decoResult.maxGf99)
                )
                StatCard(
                    title: "Max TTS",
                    value: "\(decoResult.maxTtsSec / 60) min"
                )
                StatCard(
                    title: "Model",
                    value: decoResult.model == .buhlmannZhl16c ? "Bühlmann" : "Thalmann"
                )
            }
        }
    }

    // MARK: - Helpers

    private var depthLabel: String {
        UnitFormatter.depthLabel(appState.depthUnit)
    }

    private var tempLabel: String {
        UnitFormatter.temperatureLabel(appState.temperatureUnit)
    }

    private func gasLabel(o2: Int, he: Int) -> String {
        let n2 = 100 - o2 - he
        if he > 0 {
            return "Trimix \(o2)/\(he) (N₂ \(n2)%)"
        } else if o2 == 100 {
            return "Oxygen"
        } else if o2 == 21 {
            return "Air"
        } else {
            return "Nitrox \(o2)"
        }
    }

    /// Compute ascent rate from the transit phase only (bottom_end → deco_start).
    /// Falls back to 3 m/min (~10 ft/min) if phase data is unavailable.
    private func computeTransitAscentRate(stats: DiveStats) -> Float {
        let ascentTimeSec = stats.ascentTimeSec
        guard ascentTimeSec > 0 else { return 3.0 }

        // Find depth at bottom_end_t and deco_start_t from samples
        let bottomEndT = stats.bottomEndT
        let decoStartT = stats.decoStartT
        let depthAtBottomEnd = samples.min(by: {
            abs($0.tSec - bottomEndT) < abs($1.tSec - bottomEndT)
        })?.depthM ?? stats.maxDepthM
        let depthAtDecoStart = samples.min(by: {
            abs($0.tSec - decoStartT) < abs($1.tSec - decoStartT)
        })?.depthM ?? 0

        let depthChange = depthAtBottomEnd - depthAtDecoStart
        guard depthChange > 0 else { return 3.0 }

        let ascentTimeMin = Float(ascentTimeSec) / 60.0
        return depthChange / ascentTimeMin
    }

    // MARK: - Prefill

    private func prefill() {
        // Default to actual dive mode when samples are available
        replayMode = samples.isEmpty ? .whatIfPlanning : .actualDive

        let du = appState.depthUnit
        let tu = appState.temperatureUnit

        if let s = stats {
            targetDepthText = String(format: "%.1f", UnitFormatter.depth(s.maxDepthM, unit: du))
            bottomTimeMinutes = max(1, Int(s.bottomTimeSec / 60))
            descentRateText = String(format: "%.0f", UnitFormatter.depth(s.descentRateMMin, unit: du))
            // Ascent rate: use transit phase only (bottom_end → deco_start), not overall average
            let transitAscentRate = computeTransitAscentRate(stats: s)
            ascentRateText = String(format: "%.0f", UnitFormatter.depth(transitAscentRate, unit: du))
            tempText = String(format: "%.1f", UnitFormatter.temperature(s.avgTempC, unit: tu))
        } else {
            targetDepthText = String(format: "%.1f", UnitFormatter.depth(dive.maxDepthM, unit: du))
            bottomTimeMinutes = max(1, Int(dive.bottomTimeSec / 60))
            // Standard planning rates: 9 m/min descent (~30 ft/min), 3 m/min ascent (~10 ft/min)
            descentRateText = String(format: "%.0f", UnitFormatter.depth(9.0, unit: du))
            ascentRateText = String(format: "%.0f", UnitFormatter.depth(3.0, unit: du))
            tempText = ""
        }

        // Deco model
        if let model = dive.decoModel?.lowercased() {
            if model.contains("thalmann") {
                selectedModel = .thalmannElDca
            } else {
                selectedModel = .buhlmannZhl16c
            }
        }

        gfLow = dive.gfLow ?? 30
        gfHigh = dive.gfHigh ?? 70
        gfLowText = "\(gfLow)"
        gfHighText = "\(gfHigh)"

        // Gas plan: branch on CCR vs OC
        if dive.isCcr {
            // CCR: find diluent gas
            if let diluent = gasMixes.first(where: { $0.usage == "diluent" }) {
                diluentO2Percent = max(5, min(100, Int(diluent.o2Fraction * 100)))
                diluentHePercent = max(0, min(95, Int(diluent.heFraction * 100)))
            } else if let first = gasMixes.first {
                diluentO2Percent = max(5, min(100, Int(first.o2Fraction * 100)))
                diluentHePercent = max(0, min(95, Int(first.heFraction * 100)))
            }
            originalDiluentO2 = diluentO2Percent
            originalDiluentHe = diluentHePercent
            // gasPlanEntries not used for CCR
            gasPlanEntries = []
        } else {
            // OC: populate gas plan, filtering out diluent-usage gases
            let sorted = gasMixes
                .filter { $0.usage != "diluent" }
                .sorted(by: { $0.mixIndex < $1.mixIndex })
            if sorted.isEmpty {
                gasPlanEntries = [GasPlanEntry(o2Percent: 21, hePercent: 0, switchDepthText: "")]
            } else {
                gasPlanEntries = sorted.map { mix in
                    GasPlanEntry(
                        o2Percent: max(5, min(100, Int(mix.o2Fraction * 100))),
                        hePercent: max(0, min(95, Int(mix.heFraction * 100))),
                        switchDepthText: ""
                    )
                }
            }
        }

        // CCR setpoint from samples
        if dive.isCcr {
            let maxSp = samples.compactMap(\.setpointPpo2).max() ?? 1.3
            setpointText = String(format: "%.1f", maxSp)
            originalSetpointText = setpointText
        }

        // Advanced defaults in display units
        lastStopDepthText = String(format: "%.0f", UnitFormatter.depth(3.0, unit: du))
        stopIntervalText = String(format: "%.0f", UnitFormatter.depth(3.0, unit: du))

        // Surface pressure
        if let sp = dive.surfacePressureBar {
            surfacePressureText = String(format: "%.3f", sp)
        }
    }

    // MARK: - Build params & generate

    private func buildParams() throws -> ProfileGenParams {
        let du = appState.depthUnit
        let tu = appState.temperatureUnit

        guard let depthVal = Float(targetDepthText) else {
            throw ReplayError.invalid("Target depth is not a valid number")
        }
        let depthM = UnitFormatter.depthToMetric(depthVal, from: du)
        guard depthM > 0 else {
            throw ReplayError.invalid("Target depth must be positive")
        }

        let descentRate: Double? = Float(descentRateText).map { Double(UnitFormatter.depthToMetric($0, from: du)) }
        let ascentRate: Double? = Float(ascentRateText).map { Double(UnitFormatter.depthToMetric($0, from: du)) }

        let gasPlan: [GasSwitchPlan]
        if dive.isCcr {
            // CCR: single diluent gas, no switches
            let o2 = Double(diluentO2Percent) / 100.0
            let he = Double(diluentHePercent) / 100.0
            guard o2 + he <= 1.0 else {
                throw ReplayError.invalid("Diluent: O₂ + He exceeds 100%")
            }
            let gas = GasMixInput(mixIndex: 0, o2Fraction: o2, heFraction: he)
            gasPlan = [GasSwitchPlan(gas: gas, switchDepthM: nil)]
        } else {
            // OC: bottom gas + deco gases with switch depths
            gasPlan = try gasPlanEntries.enumerated().map { index, entry in
                let o2 = Double(entry.o2Percent) / 100.0
                let he = Double(entry.hePercent) / 100.0
                guard o2 + he <= 1.0 else {
                    throw ReplayError.invalid("Gas \(index + 1): O₂ + He exceeds 100%")
                }
                let gas = GasMixInput(mixIndex: Int32(index), o2Fraction: o2, heFraction: he)
                var switchDepth: Double?
                if index > 0 {
                    guard let sd = Float(entry.switchDepthText) else {
                        throw ReplayError.invalid("Deco gas \(index): switch depth is not a valid number")
                    }
                    switchDepth = Double(UnitFormatter.depthToMetric(sd, from: du))
                }
                return GasSwitchPlan(gas: gas, switchDepthM: switchDepth)
            }
        }

        let surfacePressure = Double(surfacePressureText)
        let temp: Float? = Float(tempText).map { UnitFormatter.temperatureToMetric($0, from: tu) }
        let lastStop: Double? = Float(lastStopDepthText).map { Double(UnitFormatter.depthToMetric($0, from: du)) }
        let stopInterval: Double? = Float(stopIntervalText).map { Double(UnitFormatter.depthToMetric($0, from: du)) }
        let sp: Double? = dive.isCcr ? Double(setpointText) : nil

        return ProfileGenParams(
            targetDepthM: Double(depthM),
            bottomTimeSec: Int32(bottomTimeMinutes * 60),
            descentRateMMin: descentRate,
            ascentRateMMin: ascentRate,
            gasPlan: gasPlan,
            model: selectedModel,
            surfacePressureBar: surfacePressure,
            gfLow: selectedModel == .buhlmannZhl16c ? UInt8(min(max(gfLow, 1), 100)) : nil,
            gfHigh: selectedModel == .buhlmannZhl16c ? UInt8(min(max(gfHigh, 1), 100)) : nil,
            lastStopDepthM: lastStop,
            stopIntervalM: stopInterval,
            setpointPpo2: sp,
            thalmannPdcs: selectedModel == .thalmannElDca ? thalmannPdcs : nil,
            sampleIntervalSec: nil,
            tempC: temp
        )
    }

    private func generate() {
        focusedField = false
        errorMessage = nil
        result = nil
        isGenerating = true

        switch replayMode {
        case .actualDive:
            generateFromActualSamples()
        case .whatIfPlanning:
            generateSyntheticProfile()
        }
    }

    private func generateFromActualSamples() {
        guard !samples.isEmpty else {
            errorMessage = "No recorded samples available for this dive."
            isGenerating = false
            return
        }

        // Two engine calls:
        // 1. Full samples with planAscent: false → per-point ceiling/GF99 overlay for charting
        // 2. Truncated samples with planAscent: true → planned deco stop schedule
        let overlayParams = buildDecoSimParams(truncate: false, planAscent: false)
        let planParams = buildDecoSimParams(truncate: true, planAscent: true)

        guard !overlayParams.samples.isEmpty, !planParams.samples.isEmpty else { return }

        // Run both engine calls in parallel — they're independent and this
        // roughly halves perceived latency on larger dives.
        Task {
            async let overlayTask = Task.detached {
                try DivelogCompute.computeDecoSimulation(params: overlayParams)
            }.value
            async let plannedTask = Task.detached {
                try DivelogCompute.computeDecoSimulation(params: planParams)
            }.value
            do {
                let (overlay, planned) = try await (overlayTask, plannedTask)
                result = .actual(overlay: overlay, planned: planned)
                isGenerating = false
            } catch {
                errorMessage = error.localizedDescription
                isGenerating = false
            }
        }
    }

    private func generateSyntheticProfile() {
        let params: ProfileGenParams
        do {
            params = try buildParams()
        } catch let error as ReplayError {
            errorMessage = error.message
            isGenerating = false
            return
        } catch {
            errorMessage = error.localizedDescription
            isGenerating = false
            return
        }

        Task {
            do {
                let genResult = try await Task.detached {
                    try DivelogCompute.generateDiveProfile(params: params)
                }.value
                result = .synthetic(genResult)
                isGenerating = false
            } catch {
                errorMessage = error.localizedDescription
                isGenerating = false
            }
        }
    }

    private func buildDecoSimParams(truncate: Bool = true, planAscent: Bool = true) -> DecoSimParams {
        let du = appState.depthUnit
        let sorted = samples.sorted(by: { $0.tSec < $1.tSec })

        let useSamples: [DiveSample]
        if truncate {
            // Truncate at bottom-end for ascent planning (peak tissue loading).
            let bottomEndT: Int32
            if let s = stats, s.bottomEndT > 0 {
                bottomEndT = s.bottomEndT
            } else {
                let maxDepth = sorted.map(\.depthM).max() ?? 0
                bottomEndT = sorted.last(where: { $0.depthM >= maxDepth * 0.95 })?.tSec ?? sorted.last?.tSec ?? 0
            }
            let bottomEndIdx = sorted.lastIndex(where: { $0.tSec <= bottomEndT }) ?? (sorted.count - 1)
            useSamples = Array(sorted[...bottomEndIdx])
        } else {
            useSamples = sorted
        }

        var sampleInputs = useSamples.toSampleInputs()

        // CCR setpoint override: only if user changed it from the prefilled value.
        // Validate that the override is a valid number.
        if dive.isCcr, setpointText != originalSetpointText {
            guard let spOverride = Float(setpointText), spOverride > 0 else {
                // Will be caught by generateFromActualSamples error handling
                errorMessage = "Setpoint must be a valid positive number"
                isGenerating = false
                return DecoSimParams(
                    model: selectedModel, samples: [], gasMixes: [],
                    surfacePressureBar: nil, ascentRateMMin: nil,
                    lastStopDepthM: nil, stopIntervalM: nil,
                    gfLow: nil, gfHigh: nil, thalmannPdcs: nil,
                    planAscent: false
                )
            }
            for i in sampleInputs.indices {
                sampleInputs[i] = SampleInput(
                    tSec: sampleInputs[i].tSec,
                    depthM: sampleInputs[i].depthM,
                    tempC: sampleInputs[i].tempC,
                    setpointPpo2: sampleInputs[i].setpointPpo2,
                    ceilingM: sampleInputs[i].ceilingM,
                    gf99: sampleInputs[i].gf99,
                    gasmixIndex: sampleInputs[i].gasmixIndex,
                    ppo2: spOverride,
                    ttsSec: sampleInputs[i].ttsSec,
                    ndlSec: sampleInputs[i].ndlSec,
                    decoStopDepthM: sampleInputs[i].decoStopDepthM,
                    atPlusFiveTtsMin: sampleInputs[i].atPlusFiveTtsMin
                )
            }
        }

        // Gas mixes: use the dive's recorded gas table by default.
        // Only override for CCR if the user changed diluent from prefilled values.
        let gasMixInputs: [GasMixInput]
        let diluentChanged = dive.isCcr
            && (diluentO2Percent != originalDiluentO2 || diluentHePercent != originalDiluentHe)
        if diluentChanged {
            let o2 = Double(diluentO2Percent) / 100.0
            let he = Double(diluentHePercent) / 100.0
            gasMixInputs = [GasMixInput(mixIndex: 0, o2Fraction: o2, heFraction: he)]
        } else {
            gasMixInputs = gasMixes.toGasMixInputs()
        }

        // Compute ascent rate from the actual dive's transit phase
        let ascentRate: Double
        if let s = stats {
            ascentRate = Double(computeTransitAscentRate(stats: s))
        } else {
            ascentRate = 9.0
        }

        let surfacePressure = Double(surfacePressureText)
        let lastStop: Double? = Float(lastStopDepthText).map { Double(UnitFormatter.depthToMetric($0, from: du)) }
        let stopInterval: Double? = Float(stopIntervalText).map { Double(UnitFormatter.depthToMetric($0, from: du)) }

        return DecoSimParams(
            model: selectedModel,
            samples: sampleInputs,
            gasMixes: gasMixInputs,
            surfacePressureBar: surfacePressure,
            ascentRateMMin: ascentRate,
            lastStopDepthM: lastStop,
            stopIntervalM: stopInterval,
            gfLow: selectedModel == .buhlmannZhl16c ? UInt8(min(max(gfLow, 1), 100)) : nil,
            gfHigh: selectedModel == .buhlmannZhl16c ? UInt8(min(max(gfHigh, 1), 100)) : nil,
            thalmannPdcs: selectedModel == .thalmannElDca ? thalmannPdcs : nil,
            planAscent: planAscent
        )
    }
}

// MARK: - Supporting types

private enum ReplayError: Error {
    case invalid(String)

    var message: String {
        switch self {
        case .invalid(let msg): return msg
        }
    }
}

private struct GasPlanEntry: Identifiable {
    let id = UUID()
    var o2Percent: Int
    var hePercent: Int
    var switchDepthText: String
}
