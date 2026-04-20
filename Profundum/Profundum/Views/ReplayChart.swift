import Charts
import DivelogCore
import SwiftUI

// MARK: - Deco stop band

struct DecoStopBand: Identifiable {
    let id: Int
    let startTimeMinutes: Float
    let endTimeMinutes: Float
    /// Positive depth in display units.
    let depth: Float
    let gasLabel: String?
    let durationLabel: String
}

// MARK: - Precomputed replay chart data

struct ReplayChartData {
    let depthPoints: [DepthDataPoint]
    let maxDepth: Float
    let totalMinutes: Float

    let hasCeilingData: Bool
    let ceilingPoints: [CeilingDataPoint]

    let hasGf99Data: Bool
    let gf99DisplayRange: (min: Float, max: Float)?
    let gf99Points: [OverlayDataPoint]

    let hasSurfGfData: Bool
    let surfGfDisplayRange: (min: Float, max: Float)?
    let surfGfPoints: [OverlayDataPoint]

    let gasSwitchMarkers: [GasSwitchMarker]
    let decoStopBands: [DecoStopBand]

    let descentEndTimeMinutes: Float
    let bottomEndTimeMinutes: Float

    /// Lookup: sample tSec -> depth in display units (for scrub readout).
    let depthLookup: [Int32: Float]
    /// Lookup: sample tSec -> ceiling in metres (for scrub readout).
    let ceilingLookup: [Int32: Float]
    /// Lookup: sample tSec -> GF99 percentage (for scrub readout).
    let gf99Lookup: [Int32: Float]
    /// Lookup: sample tSec -> SurfGF percentage (for scrub readout).
    let surfGfLookup: [Int32: Float]
    /// Lookup: sample tSec -> TTS in seconds (for scrub readout).
    let ttsLookup: [Int32: Int32]
    /// Lookup: sample tSec -> NDL in seconds (for scrub readout).
    let ndlLookup: [Int32: Int32]
    /// Lookup: sample tSec -> gas label (for scrub readout).
    let gasLookup: [Int32: String]

    var domainMin: Float { -(maxDepth * 1.15) }
    var domainMax: Float { maxDepth * 0.05 }

    // MARK: - Synthetic profile initializer

    // swiftlint:disable:next function_body_length
    init(result: ProfileGenResult, depthUnit: DepthUnit) {
        let samples = result.samples
        let decoPoints = result.decoResult.points
        let gasMixes = result.gasMixes

        // -- Depth points --
        var maxD: Float = 0
        for s in samples {
            let d = UnitFormatter.depth(s.depthM, unit: depthUnit)
            if d > maxD { maxD = d }
        }
        if maxD < 1 { maxD = 30 }
        self.maxDepth = maxD

        let depthStride = max(1, samples.count / 300)
        var depths: [DepthDataPoint] = []
        depths.reserveCapacity(302)
        var di = 0
        var depthIdx = 0
        while di < samples.count {
            let t = Float(samples[di].tSec) / 60.0
            let d = UnitFormatter.depth(samples[di].depthM, unit: depthUnit)
            depths.append(DepthDataPoint(id: depthIdx, timeMinutes: t, depth: d))
            depthIdx += 1
            di += depthStride
        }
        if let last = samples.last {
            let lastT = Float(last.tSec) / 60.0
            if depths.last?.timeMinutes != lastT {
                let d = UnitFormatter.depth(last.depthM, unit: depthUnit)
                depths.append(DepthDataPoint(id: depthIdx, timeMinutes: lastT, depth: d))
            }
        }
        self.depthPoints = depths
        self.totalMinutes = depths.last?.timeMinutes ?? 0

        // -- Depth lookup (full resolution, for scrub readout) --
        var dLookup: [Int32: Float] = [:]
        for s in samples {
            dLookup[s.tSec] = UnitFormatter.depth(s.depthM, unit: depthUnit)
        }
        self.depthLookup = dLookup

        // -- Ceiling points from DecoSimResult.points --
        var ceilings: [CeilingDataPoint] = []
        var hasCeiling = false
        let ceilingStride = max(1, decoPoints.count / 300)
        var ci = 0
        var cIdx = 0
        while ci < decoPoints.count {
            let pt = decoPoints[ci]
            if pt.ceilingM > 0 {
                hasCeiling = true
                let t = Float(pt.tSec) / 60.0
                let cDepth = UnitFormatter.depth(pt.ceilingM, unit: depthUnit)
                ceilings.append(CeilingDataPoint(id: cIdx, timeMinutes: t, ceilingDepth: cDepth))
                cIdx += 1
            }
            ci += ceilingStride
        }
        self.hasCeilingData = hasCeiling
        self.ceilingPoints = ceilings

        // -- Ceiling, TTS, NDL lookups --
        var cLookup: [Int32: Float] = [:]
        var ttsLook: [Int32: Int32] = [:]
        var ndlLook: [Int32: Int32] = [:]
        for pt in decoPoints {
            if pt.ceilingM > 0 { cLookup[pt.tSec] = pt.ceilingM }
            if pt.ttsSec > 0 { ttsLook[pt.tSec] = pt.ttsSec }
            if pt.ndlSec > 0 { ndlLook[pt.tSec] = pt.ndlSec }
        }
        self.ceilingLookup = cLookup
        self.ttsLookup = ttsLook
        self.ndlLookup = ndlLook

        // -- GF99 overlay --
        let (hasGf99, gf99Range, gf99Pts) = Self.downsampleOverlay(
            decoPoints: decoPoints, maxDepth: maxD, extract: { $0.gf99 > 0 ? $0.gf99 : nil }
        )
        self.hasGf99Data = hasGf99
        self.gf99DisplayRange = gf99Range
        self.gf99Points = gf99Pts

        var g99Lookup: [Int32: Float] = [:]
        for pt in decoPoints where pt.gf99 > 0 {
            g99Lookup[pt.tSec] = pt.gf99
        }
        self.gf99Lookup = g99Lookup

        // -- SurfGF overlay --
        let (hasSurfGf, surfGfRange, surfGfPts) = Self.downsampleOverlay(
            decoPoints: decoPoints, maxDepth: maxD, extract: { $0.surfaceGf > 0 ? $0.surfaceGf : nil }
        )
        self.hasSurfGfData = hasSurfGf
        self.surfGfDisplayRange = surfGfRange
        self.surfGfPoints = surfGfPts

        var sgLookup: [Int32: Float] = [:]
        for pt in decoPoints where pt.surfaceGf > 0 {
            sgLookup[pt.tSec] = pt.surfaceGf
        }
        self.surfGfLookup = sgLookup

        // -- Gas switch markers --
        // Build mixIndex -> label dictionary for O(1) lookup
        var mixLabels: [Int32: String] = [:]
        for mix in gasMixes {
            mixLabels[mix.mixIndex] = DepthProfileChartData.gasLabel(
                o2: Float(mix.o2Fraction), he: Float(mix.heFraction)
            )
        }

        var markers: [GasSwitchMarker] = []
        var gasLook: [Int32: String] = [:]
        var currentMixIdx: Int32 = gasMixes.first?.mixIndex ?? -1
        var currentLabel = mixLabels[currentMixIdx]

        for s in samples {
            let mixIdx = s.gasmixIndex ?? currentMixIdx
            if mixIdx != currentMixIdx, mixIdx >= 0, let label = mixLabels[mixIdx] {
                currentMixIdx = mixIdx
                currentLabel = label
                markers.append(GasSwitchMarker(
                    id: markers.count,
                    timeMinutes: Float(s.tSec) / 60.0,
                    gasLabel: label,
                    color: DepthProfileChartData.gasColor(index: markers.count)
                ))
            }
            if let label = currentLabel {
                gasLook[s.tSec] = label
            }
        }
        self.gasSwitchMarkers = markers
        self.gasLookup = gasLook

        // -- Deco stop bands from pass-1 planned stops --
        // Match each planned stop to its time range in the sample profile.
        var bands: [DecoStopBand] = []
        let plannedStops = result.plannedStops
        if !plannedStops.isEmpty {
            let bottomEnd = result.bottomEndTSec
            var stopQueue = plannedStops[...]
            var bandStart: Int32?
            var bandDepthM: Float = 0

            for s in samples where s.tSec >= bottomEnd {
                guard let nextStop = stopQueue.first else { break }
                if abs(s.depthM - nextStop.depthM) < 0.5 {
                    if bandStart == nil {
                        bandStart = s.tSec
                        bandDepthM = nextStop.depthM
                    }
                } else if let start = bandStart {
                    let durSec = s.tSec - start
                    let gasLabel = mixLabels[nextStop.gasMixIndex]
                    let durLabel = durSec >= 60
                        ? "\(durSec / 60) min"
                        : "\(durSec) sec"
                    bands.append(DecoStopBand(
                        id: bands.count,
                        startTimeMinutes: Float(start) / 60.0,
                        endTimeMinutes: Float(s.tSec) / 60.0,
                        depth: UnitFormatter.depth(bandDepthM, unit: depthUnit),
                        gasLabel: gasLabel,
                        durationLabel: durLabel
                    ))
                    bandStart = nil
                    stopQueue = stopQueue.dropFirst()
                }
            }
            // Close any open band at end of dive
            if let start = bandStart, let nextStop = stopQueue.first, let lastSample = samples.last {
                let durSec = lastSample.tSec - start
                let gasLabel = mixLabels[nextStop.gasMixIndex]
                let durLabel = durSec >= 60
                    ? "\(durSec / 60) min"
                    : "\(durSec) sec"
                bands.append(DecoStopBand(
                    id: bands.count,
                    startTimeMinutes: Float(start) / 60.0,
                    endTimeMinutes: Float(lastSample.tSec) / 60.0,
                    depth: UnitFormatter.depth(bandDepthM, unit: depthUnit),
                    gasLabel: gasLabel,
                    durationLabel: durLabel
                ))
            }
        }
        self.decoStopBands = bands

        // -- Phase markers --
        self.descentEndTimeMinutes = Float(result.descentEndTSec) / 60.0
        self.bottomEndTimeMinutes = Float(result.bottomEndTSec) / 60.0
    }

    // MARK: - Actual dive initializer

    // swiftlint:disable:next function_body_length
    init(samples: [DiveSample], decoResult: DecoSimResult, gasMixes: [GasMix], depthUnit: DepthUnit) {
        let decoPoints = decoResult.points

        // -- Depth points from DiveSample --
        var maxD: Float = 0
        for s in samples {
            let d = UnitFormatter.depth(s.depthM, unit: depthUnit)
            if d > maxD { maxD = d }
        }
        if maxD < 1 { maxD = 30 }
        self.maxDepth = maxD

        let depthStride = max(1, samples.count / 300)
        var depths: [DepthDataPoint] = []
        depths.reserveCapacity(302)
        var di = 0
        var depthIdx = 0
        while di < samples.count {
            let t = Float(samples[di].tSec) / 60.0
            let d = UnitFormatter.depth(samples[di].depthM, unit: depthUnit)
            depths.append(DepthDataPoint(id: depthIdx, timeMinutes: t, depth: d))
            depthIdx += 1
            di += depthStride
        }
        if let last = samples.last {
            let lastT = Float(last.tSec) / 60.0
            if depths.last?.timeMinutes != lastT {
                let d = UnitFormatter.depth(last.depthM, unit: depthUnit)
                depths.append(DepthDataPoint(id: depthIdx, timeMinutes: lastT, depth: d))
            }
        }
        self.depthPoints = depths
        self.totalMinutes = depths.last?.timeMinutes ?? 0

        // -- Depth lookup --
        var dLookup: [Int32: Float] = [:]
        for s in samples {
            dLookup[s.tSec] = UnitFormatter.depth(s.depthM, unit: depthUnit)
        }
        self.depthLookup = dLookup

        // -- Ceiling points from DecoSimResult.points --
        var ceilings: [CeilingDataPoint] = []
        var hasCeiling = false
        let ceilingStride = max(1, decoPoints.count / 300)
        var ci = 0
        var cIdx = 0
        while ci < decoPoints.count {
            let pt = decoPoints[ci]
            if pt.ceilingM > 0 {
                hasCeiling = true
                let t = Float(pt.tSec) / 60.0
                let cDepth = UnitFormatter.depth(pt.ceilingM, unit: depthUnit)
                ceilings.append(CeilingDataPoint(id: cIdx, timeMinutes: t, ceilingDepth: cDepth))
                cIdx += 1
            }
            ci += ceilingStride
        }
        self.hasCeilingData = hasCeiling
        self.ceilingPoints = ceilings

        // -- Ceiling, TTS, NDL lookups --
        var cLookup: [Int32: Float] = [:]
        var ttsLook: [Int32: Int32] = [:]
        var ndlLook: [Int32: Int32] = [:]
        for pt in decoPoints {
            if pt.ceilingM > 0 { cLookup[pt.tSec] = pt.ceilingM }
            if pt.ttsSec > 0 { ttsLook[pt.tSec] = pt.ttsSec }
            if pt.ndlSec > 0 { ndlLook[pt.tSec] = pt.ndlSec }
        }
        self.ceilingLookup = cLookup
        self.ttsLookup = ttsLook
        self.ndlLookup = ndlLook

        // -- GF99 overlay --
        let (hasGf99, gf99Range, gf99Pts) = Self.downsampleOverlay(
            decoPoints: decoPoints, maxDepth: maxD, extract: { $0.gf99 > 0 ? $0.gf99 : nil }
        )
        self.hasGf99Data = hasGf99
        self.gf99DisplayRange = gf99Range
        self.gf99Points = gf99Pts

        var g99Lookup: [Int32: Float] = [:]
        for pt in decoPoints where pt.gf99 > 0 {
            g99Lookup[pt.tSec] = pt.gf99
        }
        self.gf99Lookup = g99Lookup

        // -- SurfGF overlay --
        let (hasSurfGf, surfGfRange, surfGfPts) = Self.downsampleOverlay(
            decoPoints: decoPoints, maxDepth: maxD, extract: { $0.surfaceGf > 0 ? $0.surfaceGf : nil }
        )
        self.hasSurfGfData = hasSurfGf
        self.surfGfDisplayRange = surfGfRange
        self.surfGfPoints = surfGfPts

        var sgLookup: [Int32: Float] = [:]
        for pt in decoPoints where pt.surfaceGf > 0 {
            sgLookup[pt.tSec] = pt.surfaceGf
        }
        self.surfGfLookup = sgLookup

        // -- Gas switch markers from gasmixIndex changes in samples --
        var mixLabels: [Int: String] = [:]
        for mix in gasMixes {
            mixLabels[mix.mixIndex] = DepthProfileChartData.gasLabel(
                o2: mix.o2Fraction, he: mix.heFraction
            )
        }

        var markers: [GasSwitchMarker] = []
        var gasLook: [Int32: String] = [:]
        var currentMixIdx: Int = gasMixes.first?.mixIndex ?? -1
        var currentLabel = mixLabels[currentMixIdx]

        for s in samples {
            let mixIdx = s.gasmixIndex ?? currentMixIdx
            if mixIdx != currentMixIdx, mixIdx >= 0, let label = mixLabels[mixIdx] {
                currentMixIdx = mixIdx
                currentLabel = label
                markers.append(GasSwitchMarker(
                    id: markers.count,
                    timeMinutes: Float(s.tSec) / 60.0,
                    gasLabel: label,
                    color: DepthProfileChartData.gasColor(index: markers.count)
                ))
            }
            if let label = currentLabel {
                gasLook[s.tSec] = label
            }
        }
        self.gasSwitchMarkers = markers
        self.gasLookup = gasLook

        // No deco stop bands for actual dives (no planned stops)
        self.decoStopBands = []

        // No phase markers for actual dives
        self.descentEndTimeMinutes = 0
        self.bottomEndTimeMinutes = 0
    }

    /// Binary search for the nearest depth point to a given time.
    func nearestDepthPoint(to time: Float) -> DepthDataPoint? {
        guard !depthPoints.isEmpty else { return nil }
        var lo = 0
        var hi = depthPoints.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if depthPoints[mid].timeMinutes < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo > 0 {
            let prev = depthPoints[lo - 1]
            let curr = depthPoints[lo]
            if abs(prev.timeMinutes - time) < abs(curr.timeMinutes - time) {
                return prev
            }
        }
        return depthPoints[lo]
    }

    /// Binary search for the nearest sample tSec to a given time in minutes.
    func nearestTSec(to timeMinutes: Float, in samples: [SampleInput]) -> Int32? {
        guard !samples.isEmpty else { return nil }
        let targetSec = Int32((timeMinutes * 60.0).rounded())
        var lo = 0
        var hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].tSec < targetSec {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo > 0 {
            let prev = samples[lo - 1].tSec
            let curr = samples[lo].tSec
            if abs(prev - targetSec) < abs(curr - targetSec) {
                return prev
            }
        }
        return samples[lo].tSec
    }

    /// Denormalize a negative Y chart value back to GF99 percentage.
    func denormalizeGf99(_ yValue: Float) -> Float {
        guard let range = gf99DisplayRange else { return 0 }
        let fraction = 1.0 + yValue / maxDepth
        return range.min + fraction * (range.max - range.min)
    }

    /// Denormalize a negative Y chart value back to SurfGF percentage.
    func denormalizeSurfGf(_ yValue: Float) -> Float {
        guard let range = surfGfDisplayRange else { return 0 }
        let fraction = 1.0 + yValue / maxDepth
        return range.min + fraction * (range.max - range.min)
    }

    // MARK: - Overlay downsampling

    private static func downsampleOverlay(
        decoPoints: [DecoSimPoint],
        maxDepth: Float,
        extract: (DecoSimPoint) -> Float?
    ) -> (hasData: Bool, range: (min: Float, max: Float)?, points: [OverlayDataPoint]) {
        var minVal: Float = .greatestFiniteMagnitude
        var maxVal: Float = -.greatestFiniteMagnitude
        var anyData = false
        for pt in decoPoints {
            if let v = extract(pt) {
                anyData = true
                if v < minVal { minVal = v }
                if v > maxVal { maxVal = v }
            }
        }
        guard anyData else { return (false, nil, []) }

        let span = maxVal - minVal
        let pad = span > 0.1 ? span * 0.15 : max(abs(minVal) * 0.1, 1)
        let range = (min: minVal - pad, max: maxVal + pad)
        let rangeDelta = range.max - range.min

        let targetCount = 300
        let stride = max(1, decoPoints.count / targetCount)
        var pts: [OverlayDataPoint] = []
        pts.reserveCapacity(targetCount + 2)
        var si = 0
        var idx = 0
        while si < decoPoints.count {
            let pt = decoPoints[si]
            let t = Float(pt.tSec) / 60.0
            if let v = extract(pt) {
                let fraction = (v - range.min) / rangeDelta
                let normalized = -(maxDepth * (1.0 - fraction))
                pts.append(OverlayDataPoint(id: idx, timeMinutes: t, normalizedValue: normalized))
                idx += 1
            }
            si += stride
        }
        if let last = decoPoints.last, let v = extract(last) {
            let lastT = Float(last.tSec) / 60.0
            if pts.last?.timeMinutes != lastT {
                let fraction = (v - range.min) / rangeDelta
                let normalized = -(maxDepth * (1.0 - fraction))
                pts.append(OverlayDataPoint(id: idx, timeMinutes: lastT, normalizedValue: normalized))
            }
        }
        return (true, range, pts)
    }
}

// MARK: - Animation speed

enum AnimationSpeed: Float, CaseIterable, Identifiable {
    case x5 = 5
    case x10 = 10
    case x30 = 30
    case x60 = 60
    case x120 = 120

    var id: Float { rawValue }

    var label: String {
        switch self {
        case .x5: "5x"
        case .x10: "10x"
        case .x30: "30x"
        case .x60: "60x"
        case .x120: "120x"
        }
    }

    var slower: AnimationSpeed? {
        guard let idx = Self.allCases.firstIndex(of: self), idx > 0 else { return nil }
        return Self.allCases[idx - 1]
    }

    var faster: AnimationSpeed? {
        guard let idx = Self.allCases.firstIndex(of: self), idx < Self.allCases.count - 1 else { return nil }
        return Self.allCases[idx + 1]
    }
}

// MARK: - Animation controller

@MainActor @Observable
final class ReplayAnimationController {
    var visibleTimeSec: Float = 0
    var isPlaying: Bool = false
    var speed: AnimationSpeed = .x30
    let totalTimeSec: Float

    private var timer: Timer?

    init(totalTimeSec: Float) {
        self.totalTimeSec = totalTimeSec
    }

    var visibleTimeMinutes: Float { visibleTimeSec / 60.0 }
    var progress: Float { totalTimeSec > 0 ? visibleTimeSec / totalTimeSec : 0 }
    var isAtEnd: Bool { visibleTimeSec >= totalTimeSec }

    var currentTimeLabel: String {
        let cur = Int(visibleTimeSec)
        let total = Int(totalTimeSec)
        return "\(cur / 60):\(String(format: "%02d", cur % 60)) / \(total / 60):\(String(format: "%02d", total % 60))"
    }

    func play() {
        guard totalTimeSec > 0 else { return }
        guard !isAtEnd else {
            reset()
            return startPlaying()
        }
        startPlaying()
    }

    func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        pause()
        visibleTimeSec = 0
    }

    func scrub(to time: Float) {
        pause()
        visibleTimeSec = min(max(time, 0), totalTimeSec)
    }

    private func startPlaying() {
        isPlaying = true
        let interval: TimeInterval = 1.0 / 30.0
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.visibleTimeSec += self.speed.rawValue * Float(interval)
                if self.visibleTimeSec >= self.totalTimeSec {
                    self.visibleTimeSec = self.totalTimeSec
                    self.pause()
                    #if os(iOS)
                    UIAccessibility.post(notification: .announcement, argument: "Profile animation complete")
                    #endif
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        // Timer is already invalidated by pause() in onDisappear;
        // MainActor isolation prevents direct access here.
    }
}

// MARK: - Replay chart view

struct ReplayChart: View {
    let data: ReplayChartData
    let visibleTimeMinutes: Float
    let samples: [SampleInput]
    var showCeiling: Bool = true
    var showGf99: Bool = false
    var showSurfGf: Bool = false
    var isFullscreen: Bool = false
    var depthUnit: DepthUnit = .meters

    @State private var selectedTime: Float?

    private var selectedPoint: DepthDataPoint? {
        guard let selectedTime else { return nil }
        return data.nearestDepthPoint(to: selectedTime)
    }

    var body: some View {
        VStack(spacing: 2) {
            readoutBar
                .opacity(selectedTime != nil ? 1 : 0)
            chartContent
        }
    }

    // MARK: - Chart content

    private var chartContent: some View {
        Chart {
            depthContent
            if showCeiling { ceilingContent }
            if showGf99 { gf99Content }
            if showSurfGf { surfGfContent }
            decoStopContent
            gasSwitchContent
            phaseMarkerContent
            scrubContent
        }
        .chartYScale(domain: data.domainMin ... data.domainMax)
        .chartXScale(domain: 0 ... data.totalMinutes)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let minutes = value.as(Float.self) {
                        Text("\(Int(minutes)) min")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let depth = value.as(Float.self) {
                        Text(String(format: "%.0f%@", abs(depth), UnitFormatter.depthLabel(depthUnit)))
                    }
                }
            }
            if showGf99 {
                AxisMarks(position: .trailing, values: .automatic) { value in
                    AxisValueLabel {
                        if let yVal = value.as(Float.self) {
                            let gf = data.denormalizeGf99(yVal)
                            if gf >= 0 { Text(String(format: "%.0f%%", gf)) }
                        }
                    }
                }
            } else if showSurfGf {
                AxisMarks(position: .trailing, values: .automatic) { value in
                    AxisValueLabel {
                        if let yVal = value.as(Float.self) {
                            let sgf = data.denormalizeSurfGf(yVal)
                            if sgf >= 0 { Text(String(format: "%.0f%%", sgf)) }
                        }
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
                                guard let plotFrame = proxy.plotFrame else { return }
                                let origin = geometry[plotFrame].origin
                                let x = value.location.x - origin.x
                                if let time: Float = proxy.value(atX: x) {
                                    selectedTime = max(0, min(time, visibleTimeMinutes))
                                }
                            }
                            .onEnded { _ in
                                selectedTime = nil
                            }
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chartAccessibilityLabel)
    }

    // MARK: - Chart layers

    @ChartContentBuilder
    private var depthContent: some ChartContent {
        ForEach(data.depthPoints.prefix(while: { $0.timeMinutes <= visibleTimeMinutes })) { point in
            LineMark(
                x: .value("Time", point.timeMinutes),
                y: .value("Depth", -point.depth),
                series: .value("Series", "Depth")
            )
            .foregroundStyle(Color.blue)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
    }

    @ChartContentBuilder
    private var ceilingContent: some ChartContent {
        if data.hasCeilingData {
            ForEach(data.ceilingPoints.prefix(while: { $0.timeMinutes <= visibleTimeMinutes })) { point in
                AreaMark(
                    x: .value("Time", point.timeMinutes),
                    yStart: .value("Surface", Float(0)),
                    yEnd: .value("Ceiling", -point.ceilingDepth)
                )
                .foregroundStyle(Color.red.opacity(0.25))
            }
            ForEach(data.ceilingPoints.prefix(while: { $0.timeMinutes <= visibleTimeMinutes })) { point in
                LineMark(
                    x: .value("Time", point.timeMinutes),
                    y: .value("Ceiling Line", -point.ceilingDepth),
                    series: .value("Series", "Ceiling")
                )
                .foregroundStyle(Color.red.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
    }

    @ChartContentBuilder
    private var gf99Content: some ChartContent {
        ForEach(data.gf99Points.prefix(while: { $0.timeMinutes <= visibleTimeMinutes })) { point in
            LineMark(
                x: .value("Time", point.timeMinutes),
                y: .value("Depth", point.normalizedValue),
                series: .value("Series", "GF99")
            )
            .foregroundStyle(Color.purple)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
    }

    @ChartContentBuilder
    private var surfGfContent: some ChartContent {
        ForEach(data.surfGfPoints.prefix(while: { $0.timeMinutes <= visibleTimeMinutes })) { point in
            LineMark(
                x: .value("Time", point.timeMinutes),
                y: .value("Depth", point.normalizedValue),
                series: .value("Series", "SurfGF")
            )
            .foregroundStyle(Color.teal)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
    }

    @ChartContentBuilder
    private var decoStopContent: some ChartContent {
        let bandHalfHeight: Float = depthUnit == .feet ? 1.0 : 0.3
        ForEach(data.decoStopBands.filter({ $0.startTimeMinutes <= visibleTimeMinutes })) { band in
            let visibleEnd = min(band.endTimeMinutes, visibleTimeMinutes)
            RectangleMark(
                xStart: .value("Start", band.startTimeMinutes),
                xEnd: .value("End", visibleEnd),
                yStart: .value("Top", -(band.depth - bandHalfHeight)),
                yEnd: .value("Bottom", -(band.depth + bandHalfHeight))
            )
            .foregroundStyle(Color.red.opacity(0.15))
        }
    }

    @ChartContentBuilder
    private var gasSwitchContent: some ChartContent {
        ForEach(data.gasSwitchMarkers.filter({ $0.timeMinutes <= visibleTimeMinutes })) { marker in
            RuleMark(x: .value("Gas Switch", marker.timeMinutes))
                .foregroundStyle(marker.color.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .leading) {
                    Text(marker.gasLabel)
                        .font(.caption2)
                        .foregroundColor(marker.color)
                        .padding(2)
                        #if os(iOS)
                        .background(Color(.systemBackground).opacity(0.8))
                        #else
                        .background(Color(.windowBackgroundColor).opacity(0.8))
                        #endif
                        .cornerRadius(3)
                }
        }
    }

    @ChartContentBuilder
    private var phaseMarkerContent: some ChartContent {
        if data.descentEndTimeMinutes > 0, data.descentEndTimeMinutes <= visibleTimeMinutes {
            RuleMark(x: .value("Descent End", data.descentEndTimeMinutes))
                .foregroundStyle(Color.gray.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 3]))
        }
        if data.bottomEndTimeMinutes > 0, data.bottomEndTimeMinutes <= visibleTimeMinutes {
            RuleMark(x: .value("Bottom End", data.bottomEndTimeMinutes))
                .foregroundStyle(Color.gray.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 3]))
        }
    }

    @ChartContentBuilder
    private var scrubContent: some ChartContent {
        if let selectedPoint {
            RuleMark(x: .value("Selected", selectedPoint.timeMinutes))
                .foregroundStyle(Color.gray.opacity(isFullscreen ? 0.7 : 0.5))
                .lineStyle(StrokeStyle(
                    lineWidth: isFullscreen ? 1.5 : 1,
                    dash: isFullscreen ? [] : [4, 4]
                ))
        }
    }

    // MARK: - Readout bar

    private var readoutBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: isFullscreen ? 12 : 8) {
                if let tSec = selectedTSec {
                    if let d = data.depthLookup[tSec] {
                        Text(String(format: "%.1f%@", d, UnitFormatter.depthLabel(depthUnit)))
                            .fontWeight(.semibold)
                    }
                    let mins = tSec / 60
                    let secs = tSec % 60
                    Text("\(mins):\(String(format: "%02d", secs))")
                        .foregroundColor(.secondary)
                    if let gas = data.gasLookup[tSec] {
                        Text(gas).foregroundColor(.mint)
                    }
                    if let ceil = data.ceilingLookup[tSec] {
                        Text("CEIL \(UnitFormatter.formatDepth(ceil, unit: depthUnit))")
                            .foregroundColor(.red)
                    }
                    if let tts = data.ttsLookup[tSec] {
                        Text("TTS \(tts / 60):\(String(format: "%02d", tts % 60))")
                            .foregroundColor(.red)
                    }
                    if let ndl = data.ndlLookup[tSec] {
                        Text("NDL \(ndl / 60):\(String(format: "%02d", ndl % 60))")
                            .foregroundColor(.green)
                    }
                    if showGf99, let gf = data.gf99Lookup[tSec] {
                        Text(String(format: "GF99 %.0f%%", gf))
                            .foregroundColor(.purple)
                    }
                    if showSurfGf, let sgf = data.surfGfLookup[tSec] {
                        Text(String(format: "SurfGF %.0f%%", sgf))
                            .foregroundColor(.teal)
                    }
                }
            }
            .font(isFullscreen ? .caption : .caption2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(readoutBackground)
        .cornerRadius(6)
    }

    private var selectedTSec: Int32? {
        guard let selectedTime else { return nil }
        return data.nearestTSec(to: selectedTime, in: samples)
    }

    private var readoutBackground: some ShapeStyle {
        #if os(iOS)
        Color(.systemBackground).opacity(0.85)
        #else
        Color(.windowBackgroundColor).opacity(0.85)
        #endif
    }

    // MARK: - Accessibility

    private var chartAccessibilityLabel: String {
        let depthStr = String(format: "%.1f%@", data.maxDepth, UnitFormatter.depthLabel(depthUnit))
        let totalMin = Int(data.totalMinutes.rounded())
        let animMin = Int(visibleTimeMinutes.rounded())
        var label = "Replay profile chart. Showing \(animMin) of \(totalMin) minutes. Maximum depth \(depthStr)."
        if !data.decoStopBands.isEmpty {
            label += " \(data.decoStopBands.count) deco stop\(data.decoStopBands.count == 1 ? "" : "s")."
        }
        if !data.gasSwitchMarkers.isEmpty {
            label += " \(data.gasSwitchMarkers.count) gas switch\(data.gasSwitchMarkers.count == 1 ? "" : "es")."
        }
        return label
    }
}

// MARK: - Replay chart section (inline in sheet)

struct ReplayChartSection: View {
    let chartData: ReplayChartData
    let samples: [SampleInput]
    let depthUnit: DepthUnit

    @State private var controller: ReplayAnimationController?
    @State private var showFullscreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Profile")
                    .font(.headline)
                Spacer()
                Button {
                    showFullscreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open fullscreen chart")
            }

            if let controller {
                ReplayChart(
                    data: chartData,
                    visibleTimeMinutes: controller.visibleTimeMinutes,
                    samples: samples,
                    depthUnit: depthUnit
                )
                .frame(height: 250)

                animationControls(controller: controller)
            }
        }
        .onAppear {
            self.controller = ReplayAnimationController(totalTimeSec: chartData.totalMinutes * 60.0)
        }
        .onDisappear {
            controller?.pause()
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showFullscreen) {
            if let controller {
                ReplayChartFullscreenView(
                    data: chartData,
                    controller: controller,
                    samples: samples,
                    depthUnit: depthUnit
                )
            }
        }
        #else
        .sheet(isPresented: $showFullscreen) {
            if let controller {
                ReplayChartFullscreenView(
                    data: chartData,
                    controller: controller,
                    samples: samples,
                    depthUnit: depthUnit
                )
                .frame(minWidth: 800)
                .frame(minHeight: 500)
            }
        }
        #endif
    }

    private func animationControls(controller: ReplayAnimationController) -> some View {
        VStack(spacing: 8) {
            // Slider
            Slider(
                value: Binding(
                    get: { controller.visibleTimeSec },
                    set: { controller.scrub(to: $0) }
                ),
                in: 0 ... max(controller.totalTimeSec, 1)
            )
            .accessibilityLabel("Animation progress")
            .accessibilityValue(controller.currentTimeLabel)

            HStack(spacing: 12) {
                // Transport controls
                Button { controller.reset() } label: {
                    Image(systemName: "backward.end.fill").frame(width: 24)
                }
                .accessibilityLabel("Reset")

                Button {
                    if let slower = controller.speed.slower { controller.speed = slower }
                } label: {
                    Image(systemName: "backward.fill").frame(width: 24)
                }
                .disabled(controller.speed.slower == nil)
                .accessibilityLabel("Slower")

                Button {
                    if controller.isPlaying { controller.pause() } else { controller.play() }
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24)
                }
                .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

                Button {
                    if let faster = controller.speed.faster { controller.speed = faster }
                } label: {
                    Image(systemName: "forward.fill").frame(width: 24)
                }
                .disabled(controller.speed.faster == nil)
                .accessibilityLabel("Faster")

                Text(controller.speed.label)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(.secondary)

                Spacer()

                Text(controller.currentTimeLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
        }
    }
}
