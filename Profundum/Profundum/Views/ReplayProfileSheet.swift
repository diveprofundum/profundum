import DivelogCore
import SwiftUI

struct ReplayProfileSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let dive: Dive
    let gasMixes: [GasMix]
    let stats: DiveStats?
    let samples: [DiveSample]

    // MARK: - Form state

    @State private var targetDepthText: String = ""
    @State private var bottomTimeMinutes: Int = 20
    @State private var descentRateText: String = ""
    @State private var ascentRateText: String = ""
    @State private var selectedModel: DecoModel = .buhlmannZhl16c
    @State private var gfLow: Int = 30
    @State private var gfHigh: Int = 70
    @State private var gasPlanEntries: [GasPlanEntry] = []
    @State private var setpointText: String = "1.3"
    @State private var surfacePressureText: String = "1.01325"
    @State private var tempText: String = ""
    @State private var lastStopDepthText: String = ""
    @State private var stopIntervalText: String = ""

    // MARK: - Result state

    @State private var result: ProfileGenResult?
    @State private var errorMessage: String?
    @State private var isGenerating = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    depthAndTimeSection
                    decoModelSection
                    if selectedModel == .buhlmannZhl16c {
                        gradientFactorsSection
                    }
                    gasPlanSection
                    if dive.isCcr {
                        ccrSetpointSection
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
            Stepper("GF Low: \(gfLow)", value: $gfLow, in: 1...100)
                .accessibilityLabel("Gradient factor low \(gfLow)")
            Stepper("GF High: \(gfHigh)", value: $gfHigh, in: 1...100)
                .accessibilityLabel("Gradient factor high \(gfHigh)")
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

    private var ccrSetpointSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CCR Setpoint")
                .font(.headline)
            HStack {
                TextField("Setpoint", text: $setpointText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 80)
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

    private var generateButton: some View {
        Button {
            generate()
        } label: {
            HStack {
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Generate Profile")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isGenerating)
        .accessibilityLabel("Generate dive profile")
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

    private func resultSummary(_ result: ProfileGenResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Result")
                .font(.headline)

            if result.decoResult.truncated {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Profile was truncated — ascent may exceed safe limits with these parameters.")
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
                    title: "Total Time",
                    value: "\(result.totalTimeSec / 60) min"
                )
                StatCard(
                    title: "Deco Time",
                    value: "\(decoTimeSec(result) / 60) min"
                )
                StatCard(
                    title: "Stops",
                    value: "\(result.decoResult.decoStops.count)"
                )
                StatCard(
                    title: "Max Ceiling",
                    value: UnitFormatter.formatDepth(
                        result.decoResult.maxCeilingM,
                        unit: appState.depthUnit
                    )
                )
                StatCard(
                    title: "Max GF99",
                    value: String(format: "%.0f%%", result.decoResult.maxGf99)
                )
                StatCard(
                    title: "Max TTS",
                    value: "\(result.decoResult.maxTtsSec / 60) min"
                )
            }

            // Phase 4 placeholder: animated chart will go here
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

    private func decoTimeSec(_ r: ProfileGenResult) -> Int32 {
        r.totalTimeSec - r.bottomEndTSec
    }


    // MARK: - Prefill

    private func prefill() {
        let du = appState.depthUnit
        let tu = appState.temperatureUnit

        if let s = stats {
            targetDepthText = String(format: "%.1f", UnitFormatter.depth(s.maxDepthM, unit: du))
            bottomTimeMinutes = max(1, Int(s.bottomTimeSec / 60))
            descentRateText = String(format: "%.0f", UnitFormatter.depth(s.descentRateMMin, unit: du))
            ascentRateText = String(format: "%.0f", UnitFormatter.depth(s.ascentRateMMin, unit: du))
            tempText = String(format: "%.1f", UnitFormatter.temperature(s.avgTempC, unit: tu))
        } else {
            targetDepthText = String(format: "%.1f", UnitFormatter.depth(dive.maxDepthM, unit: du))
            bottomTimeMinutes = max(1, Int(dive.bottomTimeSec / 60))
            descentRateText = String(format: "%.0f", UnitFormatter.depth(18.0, unit: du))
            ascentRateText = String(format: "%.0f", UnitFormatter.depth(9.0, unit: du))
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

        // Gas plan from gas mixes
        if gasMixes.isEmpty {
            gasPlanEntries = [GasPlanEntry(o2Percent: 21, hePercent: 0, switchDepthText: "")]
        } else {
            gasPlanEntries = gasMixes.sorted(by: { $0.mixIndex < $1.mixIndex }).map { mix in
                GasPlanEntry(
                    o2Percent: max(5, min(100, Int(mix.o2Fraction * 100))),
                    hePercent: max(0, min(95, Int(mix.heFraction * 100))),
                    switchDepthText: ""
                )
            }
        }

        // CCR setpoint from samples
        if dive.isCcr {
            let maxSp = samples.compactMap(\.setpointPpo2).max() ?? 1.3
            setpointText = String(format: "%.1f", maxSp)
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

        let gasPlan: [GasSwitchPlan] = try gasPlanEntries.enumerated().map { index, entry in
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
            sampleIntervalSec: nil,
            tempC: temp
        )
    }

    private func generate() {
        errorMessage = nil
        result = nil
        isGenerating = true

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
                result = genResult
                isGenerating = false
            } catch {
                errorMessage = error.localizedDescription
                isGenerating = false
            }
        }
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
