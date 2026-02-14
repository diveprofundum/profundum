import Charts
import DivelogCore
import SwiftUI

// MARK: - Precomputed chart data

struct DepthProfileChartData {
    let depthPoints: [DepthDataPoint]
    /// Positive max depth value (for display / tooltip).
    let maxDepth: Float
    let totalMinutes: Float
    let hasTemperatureVariation: Bool
    let tempDisplayRange: (min: Float, max: Float)?
    let tempPoints: [TempDataPoint]
    let hasCeilingData: Bool
    /// Time (in minutes) of the first sample with ceiling > 0, used to gate NDL display.
    let firstCeilingTimeMinutes: Float?
    let ceilingPoints: [CeilingDataPoint]
    let hasGf99Data: Bool
    let gf99DisplayRange: (min: Float, max: Float)?
    let gf99Points: [OverlayDataPoint]

    let hasAtPlusFiveData: Bool
    let atPlusFiveDisplayRange: (min: Float, max: Float)?
    let atPlusFivePoints: [OverlayDataPoint]

    let hasDeltaFiveData: Bool
    let deltaFiveDisplayRange: (min: Float, max: Float)?
    let deltaFivePoints: [OverlayDataPoint]

    let hasSurfGfData: Bool
    let surfGfDisplayRange: (min: Float, max: Float)?
    let surfGfPoints: [OverlayDataPoint]
    /// SurfGF lookup by sample tSec for tooltip display.
    let surfGfLookup: [Int32: Float]

    let gasSwitchMarkers: [GasSwitchMarker]
    let setpointSwitchMarkers: [SetpointSwitchMarker]

    // swiftlint:disable:next function_body_length
    init(
        samples: [DiveSample],
        depthUnit: DepthUnit,
        temperatureUnit: TemperatureUnit,
        gasMixes: [GasMix] = [],
        needsSurfGf: Bool = false
    ) {
        var maxD: Float = 0
        var minC: Float = .greatestFiniteMagnitude
        var maxC: Float = -.greatestFiniteMagnitude

        // First pass: find extremes
        for s in samples {
            let d = UnitFormatter.depth(s.depthM, unit: depthUnit)
            if d > maxD { maxD = d }
            let c = s.tempC
            if c < minC { minC = c }
            if c > maxC { maxC = c }
        }

        if maxD < 1 { maxD = 30 }
        self.maxDepth = maxD

        // Downsample depth to ~300 points
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
        // Always include last sample
        if let last = samples.last {
            let lastT = Float(last.tSec) / 60.0
            if depths.last?.timeMinutes != lastT {
                let d = UnitFormatter.depth(last.depthM, unit: depthUnit)
                depths.append(DepthDataPoint(id: depthIdx, timeMinutes: lastT, depth: d))
            }
        }

        self.depthPoints = depths
        self.totalMinutes = depths.last?.timeMinutes ?? 0

        let hasVariation = maxC - minC > 0.1 && !samples.isEmpty
        self.hasTemperatureVariation = hasVariation

        if hasVariation {
            let a = UnitFormatter.temperature(minC, unit: temperatureUnit)
            let b = UnitFormatter.temperature(maxC, unit: temperatureUnit)
            let lo = min(a, b)
            let hi = max(a, b)
            let pad = (hi - lo) * 0.15
            let range = (min: lo - pad, max: hi + pad)
            self.tempDisplayRange = range

            // Second pass: smooth + downsample temp to ~300 points
            // Stride controls output count; window controls smoothing independently.
            // Temperature sensors have thermal mass — real changes happen over minutes,
            // so a ~1-2 min window removes integer-resolution noise without losing thermoclines.
            let targetCount = 300
            let stride = max(1, samples.count / targetCount)
            let halfWindow = max(5, samples.count / 40)
            var temps: [TempDataPoint] = []
            temps.reserveCapacity(targetCount + 2)
            var i = 0
            var tempIdx = 0
            while i < samples.count {
                let t = Float(samples[i].tSec) / 60.0
                let wStart = max(0, i - halfWindow)
                let wEnd = min(samples.count - 1, i + halfWindow)
                var tempSum: Float = 0
                for j in wStart ... wEnd {
                    tempSum += samples[j].tempC
                }
                let avgC = tempSum / Float(wEnd - wStart + 1)
                let display = UnitFormatter.temperature(avgC, unit: temperatureUnit)
                let fraction = (display - range.min) / (range.max - range.min)
                let normalized = -(maxD * (1.0 - fraction))
                temps.append(TempDataPoint(id: tempIdx, timeMinutes: t, normalizedValue: normalized))
                tempIdx += 1
                i += stride
            }
            // Always include last sample
            if let last = samples.last {
                let lastT = Float(last.tSec) / 60.0
                if temps.last?.timeMinutes != lastT {
                    let display = UnitFormatter.temperature(last.tempC, unit: temperatureUnit)
                    let fraction = (display - range.min) / (range.max - range.min)
                    let normalized = -(maxD * (1.0 - fraction))
                    temps.append(TempDataPoint(id: tempIdx, timeMinutes: lastT, normalizedValue: normalized))
                }
            }
            self.tempPoints = temps
        } else {
            self.tempDisplayRange = nil
            self.tempPoints = []
        }

        // Ceiling pass: iterate ALL samples to catch every deco transition,
        // but only emit data points at stride intervals to keep ~300 output points.
        // Gap tolerance ignores brief ceiling interruptions (data noise between stops).
        // Rolling max window smooths oscillations at stop boundaries for display.
        let firstCeilingIdx = samples.firstIndex(where: { ($0.ceilingM ?? 0) > 0 })
        let anyCeiling = firstCeilingIdx != nil
        self.hasCeilingData = anyCeiling
        if anyCeiling {
            self.firstCeilingTimeMinutes = firstCeilingIdx.map { Float(samples[$0].tSec) / 60.0 }
            // Pre-compute rolling max ceiling (±15 sec window) to smooth stop oscillations.
            // Uses sample timestamps to determine the window rather than fixed index count.
            let halfWindowSec: Int32 = 15
            var smoothedCeiling = [Float](repeating: 0, count: samples.count)
            var windowStart = 0
            var windowEnd = 0
            for i in 0 ..< samples.count {
                let tSec = samples[i].tSec
                while windowStart < samples.count && samples[windowStart].tSec < tSec - halfWindowSec {
                    windowStart += 1
                }
                while windowEnd < samples.count && samples[windowEnd].tSec <= tSec + halfWindowSec {
                    windowEnd += 1
                }
                var maxInWindow: Float = 0
                for j in windowStart ..< windowEnd {
                    let c = samples[j].ceilingM ?? 0
                    if c > maxInWindow { maxInWindow = c }
                }
                smoothedCeiling[i] = maxInWindow
            }

            let cStride = max(1, samples.count / 300)
            let gapTolerance = 5
            var cPoints: [CeilingDataPoint] = []
            cPoints.reserveCapacity(302)
            var cIdx = 0
            var wasInDeco = false
            var lastEmitted = -cStride
            var gapLength = 0
            var gapStartIndex = 0

            for i in 0 ..< samples.count {
                let cm = smoothedCeiling[i]
                let inDeco = cm > 0
                let t = Float(samples[i].tSec) / 60.0

                if wasInDeco {
                    if inDeco {
                        gapLength = 0
                        if i - lastEmitted >= cStride {
                            let d = UnitFormatter.depth(cm, unit: depthUnit)
                            cPoints.append(CeilingDataPoint(id: cIdx, timeMinutes: t, ceilingDepth: d))
                            cIdx += 1
                            lastEmitted = i
                        }
                    } else {
                        if gapLength == 0 { gapStartIndex = i }
                        gapLength += 1
                        if gapLength >= gapTolerance {
                            let exitT = Float(samples[gapStartIndex].tSec) / 60.0
                            cPoints.append(CeilingDataPoint(id: cIdx, timeMinutes: exitT, ceilingDepth: 0))
                            cIdx += 1
                            wasInDeco = false
                            gapLength = 0
                        }
                    }
                } else if inDeco {
                    cPoints.append(CeilingDataPoint(id: cIdx, timeMinutes: t, ceilingDepth: 0))
                    cIdx += 1
                    let d = UnitFormatter.depth(cm, unit: depthUnit)
                    cPoints.append(CeilingDataPoint(id: cIdx, timeMinutes: t, ceilingDepth: d))
                    cIdx += 1
                    lastEmitted = i
                    wasInDeco = true
                    gapLength = 0
                }
            }

            // Close the area if we end mid-deco (including during a gap).
            // Use smoothed value for consistency with the rest of the rendered ceiling.
            if wasInDeco {
                let lastIdx = samples.count - 1
                let lastT = Float(samples[lastIdx].tSec) / 60.0
                if cPoints.last?.timeMinutes != lastT {
                    let cm = smoothedCeiling[lastIdx]
                    if cm > 0 {
                        let d = UnitFormatter.depth(cm, unit: depthUnit)
                        cPoints.append(CeilingDataPoint(id: cIdx, timeMinutes: lastT, ceilingDepth: d))
                    } else {
                        cPoints.append(CeilingDataPoint(id: cIdx, timeMinutes: lastT, ceilingDepth: 0))
                    }
                }
            }
            self.ceilingPoints = cPoints
        } else {
            self.firstCeilingTimeMinutes = nil
            self.ceilingPoints = []
        }

        // GF99 overlay
        let gf99Values: [Float?] = samples.map { s in
            guard let g = s.gf99, g > 0 else { return nil }
            return g
        }
        let gf99Result = Self.downsampleOverlay(samples: samples, values: gf99Values, maxDepth: maxD)
        self.hasGf99Data = gf99Result.hasData
        self.gf99DisplayRange = gf99Result.range
        self.gf99Points = gf99Result.points

        // @+5 TTS overlay
        let atPlusFiveValues: [Float?] = samples.map { s in s.atPlusFiveTtsMin.map { Float($0) } }
        let atPlusFiveResult = Self.downsampleOverlay(samples: samples, values: atPlusFiveValues, maxDepth: maxD)
        self.hasAtPlusFiveData = atPlusFiveResult.hasData
        self.atPlusFiveDisplayRange = atPlusFiveResult.range
        self.atPlusFivePoints = atPlusFiveResult.points

        // Δ+5 TTS overlay
        let deltaFiveValues: [Float?] = samples.map { s in s.deltaFiveTtsMin.map { Float($0) } }
        let deltaFiveResult = Self.downsampleOverlay(samples: samples, values: deltaFiveValues, maxDepth: maxD)
        self.hasDeltaFiveData = deltaFiveResult.hasData
        self.deltaFiveDisplayRange = deltaFiveResult.range
        self.deltaFivePoints = deltaFiveResult.points

        // SurfGF overlay (lazy — only run Bühlmann simulation when requested)
        if needsSurfGf {
            let sampleInputs = samples.map { s in
                SampleInput(
                    tSec: s.tSec,
                    depthM: s.depthM,
                    tempC: s.tempC,
                    setpointPpo2: s.setpointPpo2,
                    ceilingM: s.ceilingM,
                    gf99: s.gf99,
                    gasmixIndex: s.gasmixIndex.map { Int32($0) },
                    ppo2: s.ppo2_1 ?? s.setpointPpo2
                )
            }
            let gasMixInputs = gasMixes.map { mix in
                GasMixInput(
                    mixIndex: Int32(mix.mixIndex),
                    o2Fraction: Double(mix.o2Fraction),
                    heFraction: Double(mix.heFraction)
                )
            }
            let surfGfResult = DivelogCompute.computeSurfaceGf(
                samples: sampleInputs,
                gasMixes: gasMixInputs
            )

            var surfGfLookupLocal: [Int32: Float] = [:]
            for pt in surfGfResult {
                surfGfLookupLocal[pt.tSec] = pt.surfaceGf
            }
            self.surfGfLookup = surfGfLookupLocal

            let surfGfValues: [Float?] = samples.map { s in
                guard let sgf = surfGfLookupLocal[s.tSec], sgf > 0.1 else { return nil }
                return sgf
            }
            let surfGfRes = Self.downsampleOverlay(samples: samples, values: surfGfValues, maxDepth: maxD)
            self.hasSurfGfData = surfGfRes.hasData
            self.surfGfDisplayRange = surfGfRes.range
            self.surfGfPoints = surfGfRes.points
        } else {
            self.hasSurfGfData = false
            self.surfGfDisplayRange = nil
            self.surfGfPoints = []
            self.surfGfLookup = [:]
        }

        // Gas switch detection
        var gasSwitchMarkersLocal: [GasSwitchMarker] = []
        var prevGasmixIdx: Int?
        for s in samples {
            guard let idx = s.gasmixIndex else { continue }
            if let prev = prevGasmixIdx, idx != prev {
                let mix = gasMixes.first(where: { $0.mixIndex == idx })
                let label = Self.gasLabel(o2: mix?.o2Fraction ?? 0.21, he: mix?.heFraction ?? 0)
                gasSwitchMarkersLocal.append(GasSwitchMarker(
                    id: gasSwitchMarkersLocal.count,
                    timeMinutes: Float(s.tSec) / 60.0,
                    gasLabel: label,
                    color: Self.gasColor(index: idx)
                ))
            }
            prevGasmixIdx = idx
        }
        self.gasSwitchMarkers = gasSwitchMarkersLocal

        // Setpoint switch detection
        var spSwitchMarkersLocal: [SetpointSwitchMarker] = []
        var prevSetpoint: Float?
        for s in samples {
            guard let sp = s.setpointPpo2 else { continue }
            if let prev = prevSetpoint, abs(sp - prev) > 0.05 {
                spSwitchMarkersLocal.append(SetpointSwitchMarker(
                    id: spSwitchMarkersLocal.count,
                    timeMinutes: Float(s.tSec) / 60.0,
                    setpoint: sp
                ))
            }
            prevSetpoint = sp
        }
        self.setpointSwitchMarkers = spSwitchMarkersLocal
    }

    /// Padded Y domain bounds (negative depth scale).
    var domainMin: Float { -(maxDepth * 1.15) }
    var domainMax: Float { maxDepth * 0.05 }

    // MARK: - Downsample helper

    /// Downsample, smooth, and normalize an overlay series to the depth Y-axis.
    ///
    /// - Parameters:
    ///   - samples: Full-resolution dive samples (for timing information).
    ///   - values: One value per sample (`nil` = no data at that point).
    ///   - maxDepth: Maximum displayed depth (positive), used for Y-axis normalization.
    /// - Returns: Whether data exists, the display range, and the downsampled points.
    private static func downsampleOverlay(
        samples: [DiveSample],
        values: [Float?],
        maxDepth: Float
    ) -> (hasData: Bool, range: (min: Float, max: Float)?, points: [OverlayDataPoint]) {
        guard samples.count == values.count else {
            return (false, nil, [])
        }

        var minVal: Float = .greatestFiniteMagnitude
        var maxVal: Float = -.greatestFiniteMagnitude
        var anyData = false
        for v in values {
            if let v {
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
        let stride = max(1, samples.count / targetCount)
        let halfWindow = max(5, samples.count / 40)
        var pts: [OverlayDataPoint] = []
        pts.reserveCapacity(targetCount + 2)
        var si = 0
        var idx = 0
        while si < samples.count {
            let t = Float(samples[si].tSec) / 60.0
            let wStart = max(0, si - halfWindow)
            let wEnd = min(samples.count - 1, si + halfWindow)
            var sum: Float = 0
            var count = 0
            for j in wStart ... wEnd {
                if let v = values[j] {
                    sum += v
                    count += 1
                }
            }
            if count > 0 {
                let avg = sum / Float(count)
                let fraction = (avg - range.min) / rangeDelta
                let normalized = -(maxDepth * (1.0 - fraction))
                pts.append(OverlayDataPoint(id: idx, timeMinutes: t, normalizedValue: normalized))
                idx += 1
            }
            si += stride
        }
        // Always include last sample
        if let lastVal = values[samples.count - 1] {
            let lastT = Float(samples[samples.count - 1].tSec) / 60.0
            if pts.last?.timeMinutes != lastT {
                let fraction = (lastVal - range.min) / rangeDelta
                let normalized = -(maxDepth * (1.0 - fraction))
                pts.append(OverlayDataPoint(id: idx, timeMinutes: lastT, normalizedValue: normalized))
            }
        }

        return (true, range, pts)
    }

    // MARK: - Gas label helpers

    /// Human-readable gas mix label from O2 and He fractions (0–1 scale).
    static func gasLabel(o2: Float, he: Float) -> String {
        let o2Pct = Int(o2 * 100)
        let hePct = Int(he * 100)
        if hePct > 0 {
            return "Tx \(o2Pct)/\(hePct)"
        } else if o2Pct == 21 {
            return "Air"
        } else if o2Pct == 100 {
            return "O2"
        } else {
            return "Nx\(o2Pct)"
        }
    }

    /// Rotating color palette for gas switch markers.
    static func gasColor(index: Int) -> Color {
        let palette: [Color] = [.mint, .green, .orange, .pink]
        return palette[index % palette.count]
    }

    // MARK: - Lookup helpers

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
            return abs(prev.timeMinutes - time) <= abs(curr.timeMinutes - time) ? prev : curr
        }
        return depthPoints[lo]
    }

    /// Accurate depth display string from full-resolution samples.
    func nearestDepthDisplay(to time: Float, samples: [DiveSample], unit: DepthUnit) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        return UnitFormatter.formatDepth(samples[idx].depthM, unit: unit)
    }

    /// Elapsed dive time for the nearest sample, formatted as mm:ss.
    func nearestElapsedTime(to time: Float, samples: [DiveSample]) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        let totalSec = Int(samples[idx].tSec)
        let minutes = totalSec / 60
        let seconds = totalSec % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Temperature display string for the nearest sample.
    func nearestTempDisplay(to time: Float, samples: [DiveSample], unit: TemperatureUnit) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        return UnitFormatter.formatTemperature(samples[idx].tempC, unit: unit)
    }

    /// Binary search returning the nearest sample to a given time.
    func nearestSampleIndex(to time: Float, in samples: [DiveSample]) -> Int? {
        guard !samples.isEmpty else { return nil }
        var lo = 0
        var hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if Float(samples[mid].tSec) / 60.0 < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo > 0 {
            let prevTime = Float(samples[lo - 1].tSec) / 60.0
            let currTime = Float(samples[lo].tSec) / 60.0
            if abs(prevTime - time) < abs(currTime - time) {
                return lo - 1
            }
        }
        return lo
    }

    /// Ceiling display string for the nearest sample.
    /// Reads the raw dive computer value (not the smoothed display value) so the tooltip
    /// shows exactly what the diver saw on their wrist computer.
    func nearestCeilingDisplay(to time: Float, samples: [DiveSample], unit: DepthUnit) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        guard let cm = samples[idx].ceilingM, cm > 0 else { return nil }
        return UnitFormatter.formatDepth(cm, unit: unit)
    }

    /// TTS display string for the nearest sample.
    /// Only returns a value when the sample is in deco (ceiling > 0), since TTS
    /// outside deco is just ascent time and not useful in the tooltip.
    func nearestTtsDisplay(to time: Float, samples: [DiveSample]) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        guard let cm = samples[idx].ceilingM, cm > 0 else { return nil }
        guard let tts = samples[idx].ttsSec, tts > 0 else { return nil }
        let minutes = tts / 60
        let seconds = tts % 60
        if minutes > 0 {
            return "\(minutes):\(String(format: "%02d", seconds))"
        }
        return "\(seconds)s"
    }

    /// NDL display string for the nearest sample.
    /// Returns nil if the sample has a ceiling, is past the first deco obligation, or has no NDL data.
    func nearestNdlDisplay(to time: Float, samples: [DiveSample]) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        // Only show NDL when not in deco (no ceiling)
        if let cm = samples[idx].ceilingM, cm > 0 { return nil }
        // Don't show NDL after deco has been entered — only pre-deco portion
        if let firstCeiling = firstCeilingTimeMinutes, time >= firstCeiling { return nil }
        guard let ndl = samples[idx].ndlSec, ndl > 0 else { return nil }
        let minutes = ndl / 60
        return "\(minutes) min"
    }

    /// Gas label for the nearest sample, looking up gasmixIndex in the provided gas mixes.
    func nearestGasDisplay(to time: Float, samples: [DiveSample], gasMixes: [GasMix]) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        guard let mixIdx = samples[idx].gasmixIndex else { return nil }
        let mix = gasMixes.first(where: { $0.mixIndex == mixIdx })
        return Self.gasLabel(o2: mix?.o2Fraction ?? 0.21, he: mix?.heFraction ?? 0)
    }

    /// Denormalize a negative Y chart value back to display temperature.
    func denormalizeTemp(_ yValue: Float) -> Float {
        guard let range = tempDisplayRange else { return 0 }
        let fraction = (maxDepth + yValue) / maxDepth
        return range.min + fraction * (range.max - range.min)
    }

    /// GF99 display string for the nearest sample.
    func nearestGf99Display(to time: Float, samples: [DiveSample]) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        guard let gf = samples[idx].gf99, gf > 0 else { return nil }
        return String(format: "%.0f%%", gf)
    }

    /// Denormalize a negative Y chart value back to GF99 percentage.
    func denormalizeGf99(_ yValue: Float) -> Float {
        guard let range = gf99DisplayRange else { return 0 }
        let fraction = (maxDepth + yValue) / maxDepth
        return max(0, range.min + fraction * (range.max - range.min))
    }

    /// @+5 TTS display string for the nearest sample.
    func nearestAtPlusFiveDisplay(to time: Float, samples: [DiveSample]) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        guard let v = samples[idx].atPlusFiveTtsMin else { return nil }
        return "\(v) min"
    }

    /// Δ+5 display string for the nearest sample.
    func nearestDeltaFiveDisplay(to time: Float, samples: [DiveSample]) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        guard let v = samples[idx].deltaFiveTtsMin else { return nil }
        if v > 0 {
            return "+\(v) min"
        } else if v < 0 {
            return "\u{2212}\(abs(v)) min"
        }
        return "0 min"
    }

    /// SurfGF display string for the nearest sample time, using precomputed lookup.
    func nearestSurfGfDisplay(to time: Float, samples: [DiveSample]) -> String? {
        guard let idx = nearestSampleIndex(to: time, in: samples) else { return nil }
        guard let sgf = surfGfLookup[samples[idx].tSec], sgf > 0.1 else { return nil }
        return String(format: "%.0f%%", sgf)
    }

    /// Denormalize a negative Y chart value back to @+5 TTS minutes.
    func denormalizeAtPlusFive(_ yValue: Float) -> Float {
        guard let range = atPlusFiveDisplayRange else { return 0 }
        let fraction = (maxDepth + yValue) / maxDepth
        return range.min + fraction * (range.max - range.min)
    }

    /// Denormalize a negative Y chart value back to Δ+5 minutes (can be negative).
    func denormalizeDeltaFive(_ yValue: Float) -> Float {
        guard let range = deltaFiveDisplayRange else { return 0 }
        let fraction = (maxDepth + yValue) / maxDepth
        return range.min + fraction * (range.max - range.min)
    }

    /// Denormalize a negative Y chart value back to SurfGF percentage.
    func denormalizeSurfGf(_ yValue: Float) -> Float {
        guard let range = surfGfDisplayRange else { return 0 }
        let fraction = (maxDepth + yValue) / maxDepth
        return max(0, range.min + fraction * (range.max - range.min))
    }
}

// MARK: - Chart view

struct DepthProfileChart: View {
    let samples: [DiveSample]
    var depthUnit: DepthUnit = .meters
    var temperatureUnit: TemperatureUnit = .celsius
    var showTemperature: Bool = false
    var showGf99: Bool = false
    var showAtPlusFive: Bool = false
    var showDeltaFive: Bool = false
    var showSurfGf: Bool = false
    var gasMixes: [GasMix] = []
    var isFullscreen: Bool = false

    @State private var chartData: DepthProfileChartData?
    @State private var selectedTime: Float?

    private var selectedPoint: DepthDataPoint? {
        guard let selectedTime, let data = chartData else { return nil }
        return data.nearestDepthPoint(to: selectedTime)
    }

    private var selectedDepthDisplay: String? {
        guard let selectedTime, let data = chartData else { return nil }
        return data.nearestDepthDisplay(to: selectedTime, samples: samples, unit: depthUnit)
    }

    private var selectedElapsedTime: String? {
        guard let selectedTime, let data = chartData else { return nil }
        return data.nearestElapsedTime(to: selectedTime, samples: samples)
    }

    private var selectedTempDisplay: String? {
        guard let selectedTime, showTemperature, let data = chartData else { return nil }
        return data.nearestTempDisplay(to: selectedTime, samples: samples, unit: temperatureUnit)
    }

    private var selectedCeilingDisplay: String? {
        guard let selectedTime, let data = chartData, data.hasCeilingData else { return nil }
        return data.nearestCeilingDisplay(to: selectedTime, samples: samples, unit: depthUnit)
    }

    private var selectedTtsDisplay: String? {
        guard let selectedTime, let data = chartData, data.hasCeilingData else { return nil }
        return data.nearestTtsDisplay(to: selectedTime, samples: samples)
    }

    private var selectedNdlDisplay: String? {
        guard let selectedTime, let data = chartData else { return nil }
        return data.nearestNdlDisplay(to: selectedTime, samples: samples)
    }

    private var selectedGf99Display: String? {
        guard let selectedTime, showGf99, let data = chartData, data.hasGf99Data else { return nil }
        return data.nearestGf99Display(to: selectedTime, samples: samples)
    }

    private var selectedAtPlusFiveDisplay: String? {
        guard let selectedTime, showAtPlusFive, let data = chartData, data.hasAtPlusFiveData else { return nil }
        return data.nearestAtPlusFiveDisplay(to: selectedTime, samples: samples)
    }

    private var selectedDeltaFiveDisplay: String? {
        guard let selectedTime, showDeltaFive, let data = chartData, data.hasDeltaFiveData else { return nil }
        return data.nearestDeltaFiveDisplay(to: selectedTime, samples: samples)
    }

    private var selectedSurfGfDisplay: String? {
        guard let selectedTime, showSurfGf, let data = chartData, data.hasSurfGfData else { return nil }
        return data.nearestSurfGfDisplay(to: selectedTime, samples: samples)
    }

    private var selectedGasDisplay: String? {
        guard let selectedTime, let data = chartData else { return nil }
        guard !data.gasSwitchMarkers.isEmpty else { return nil }
        return data.nearestGasDisplay(to: selectedTime, samples: samples, gasMixes: gasMixes)
    }

    private var selectedSetpointDisplay: String? {
        guard let selectedTime, let data = chartData else { return nil }
        guard !data.setpointSwitchMarkers.isEmpty else { return nil }
        guard let idx = data.nearestSampleIndex(to: selectedTime, in: samples) else { return nil }
        guard let sp = samples[idx].setpointPpo2 else { return nil }
        return String(format: "SP %.2f", sp)
    }

    // MARK: - Accessibility

    private var chartAccessibilityLabel: String {
        guard let data = chartData else { return "Depth profile chart" }
        let depthStr = String(format: "%.1f%@", data.maxDepth, UnitFormatter.depthLabel(depthUnit))
        let totalMinutes = Int(data.totalMinutes.rounded())
        var label = "Depth profile chart. Maximum depth \(depthStr) over \(totalMinutes) minutes."
        if showTemperature {
            let temps = samples.map(\.tempC)
            if let loC = temps.min(), let hiC = temps.max() {
                let loDisp = UnitFormatter.formatTemperature(loC, unit: temperatureUnit)
                let hiDisp = UnitFormatter.formatTemperature(hiC, unit: temperatureUnit)
                label += " Temperature overlay active, ranging from \(loDisp) to \(hiDisp)."
            }
        }
        if data.hasCeilingData, let maxCeiling = samples.compactMap(\.ceilingM).max(), maxCeiling > 0 {
            let maxCeilingDisp = UnitFormatter.formatDepth(maxCeiling, unit: depthUnit)
            label += " Deco ceiling shown, maximum ceiling \(maxCeilingDisp)."
        }
        if showGf99, data.hasGf99Data {
            let gf99Values = samples.compactMap(\.gf99).filter { $0 > 0 }
            if let loGf = gf99Values.min(), let hiGf = gf99Values.max() {
                let loStr = String(format: "%.0f%%", loGf)
                let hiStr = String(format: "%.0f%%", hiGf)
                label += " GF99 overlay active, ranging from \(loStr) to \(hiStr)."
            }
        }
        if showAtPlusFive, data.hasAtPlusFiveData { label += " @+5 TTS overlay active." }
        if showDeltaFive, data.hasDeltaFiveData { label += " \u{0394}+5 overlay active." }
        if showSurfGf, data.hasSurfGfData { label += " SurfGF overlay active." }
        if !data.gasSwitchMarkers.isEmpty {
            let n = data.gasSwitchMarkers.count
            label += " \(n) gas switch\(n == 1 ? "" : "es") marked."
        }
        if !data.setpointSwitchMarkers.isEmpty {
            let n = data.setpointSwitchMarkers.count
            label += " \(n) setpoint switch\(n == 1 ? "" : "es") marked."
        }
        return label
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 2) {
            readoutBar
                .opacity(selectedTime != nil ? 1 : 0)

            Group {
                if let data = chartData {
                    chartContent(data: data)
                } else {
                    Color.clear
                }
            }
        }
        .padding(.leading, 4)
        .onAppear {
            buildChartData()
        }
        .onChange(of: samples.count) { _, _ in
            buildChartData()
        }
        .onChange(of: depthUnit) { _, _ in
            buildChartData()
        }
        .onChange(of: temperatureUnit) { _, _ in
            buildChartData()
        }
        .onChange(of: gasMixes.count) { _, _ in
            buildChartData()
        }
        .onChange(of: showSurfGf) { _, newValue in
            if newValue { buildChartData() }
        }
    }

    // MARK: - Chart

    @ChartContentBuilder
    private func ceilingContent(data: DepthProfileChartData) -> some ChartContent {
        if data.hasCeilingData {
            ForEach(data.ceilingPoints) { point in
                AreaMark(
                    x: .value("Time", point.timeMinutes),
                    yStart: .value("Surface", Float(0)),
                    yEnd: .value("Ceiling", -point.ceilingDepth)
                )
                .foregroundStyle(Color.red.opacity(0.25))
            }
            // Trace ceiling depth as a line so shallow ceilings remain visible
            ForEach(data.ceilingPoints) { point in
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
    private func depthContent(data: DepthProfileChartData) -> some ChartContent {
        ForEach(data.depthPoints) { point in
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
    private func temperatureContent(data: DepthProfileChartData) -> some ChartContent {
        if showTemperature {
            ForEach(data.tempPoints) { point in
                LineMark(
                    x: .value("Time", point.timeMinutes),
                    y: .value("Depth", point.normalizedValue),
                    series: .value("Series", "Temperature")
                )
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
    }

    @ChartContentBuilder
    private func gf99Content(data: DepthProfileChartData) -> some ChartContent {
        if showGf99 {
            ForEach(data.gf99Points) { point in
                LineMark(
                    x: .value("Time", point.timeMinutes),
                    y: .value("Depth", point.normalizedValue),
                    series: .value("Series", "GF99")
                )
                .foregroundStyle(Color.purple)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
    }

    @ChartContentBuilder
    private func atPlusFiveContent(data: DepthProfileChartData) -> some ChartContent {
        if showAtPlusFive {
            ForEach(data.atPlusFivePoints) { point in
                LineMark(
                    x: .value("Time", point.timeMinutes),
                    y: .value("Depth", point.normalizedValue),
                    series: .value("Series", "@+5")
                )
                .foregroundStyle(Color.cyan)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 3]))
            }
        }
    }

    @ChartContentBuilder
    private func deltaFiveContent(data: DepthProfileChartData) -> some ChartContent {
        if showDeltaFive {
            ForEach(data.deltaFivePoints) { point in
                LineMark(
                    x: .value("Time", point.timeMinutes),
                    y: .value("Depth", point.normalizedValue),
                    series: .value("Series", "\u{0394}+5")
                )
                .foregroundStyle(Color.yellow)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
    }

    @ChartContentBuilder
    private func surfGfContent(data: DepthProfileChartData) -> some ChartContent {
        if showSurfGf {
            ForEach(data.surfGfPoints) { point in
                LineMark(
                    x: .value("Time", point.timeMinutes),
                    y: .value("Depth", point.normalizedValue),
                    series: .value("Series", "SurfGF")
                )
                .foregroundStyle(Color.teal)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
    }

    @ChartContentBuilder
    private func gasSwitchContent(data: DepthProfileChartData) -> some ChartContent {
        ForEach(data.gasSwitchMarkers) { marker in
            RuleMark(x: .value("Time", marker.timeMinutes))
                .foregroundStyle(marker.color.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text(marker.gasLabel)
                        .font(.system(size: isFullscreen ? 10 : 8, weight: .semibold))
                        .foregroundStyle(marker.color)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(annotationBackground)
                        .cornerRadius(3)
                }
        }
    }

    @ChartContentBuilder
    private func setpointSwitchContent(data: DepthProfileChartData) -> some ChartContent {
        ForEach(data.setpointSwitchMarkers) { marker in
            RuleMark(x: .value("Time", marker.timeMinutes))
                .foregroundStyle(Color.pink.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text(String(format: "SP %.1f", marker.setpoint))
                        .font(.system(size: isFullscreen ? 10 : 8, weight: .semibold))
                        .foregroundStyle(Color.pink)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(annotationBackground)
                        .cornerRadius(3)
                }
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

    private func chartContent(data: DepthProfileChartData) -> some View {
        Chart {
            depthContent(data: data)
            ceilingContent(data: data)
            temperatureContent(data: data)
            gf99Content(data: data)
            atPlusFiveContent(data: data)
            deltaFiveContent(data: data)
            surfGfContent(data: data)
            gasSwitchContent(data: data)
            setpointSwitchContent(data: data)
            scrubContent
        }
        .chartYScale(domain: data.domainMin ... data.domainMax)
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
                            if gf >= 0 {
                                Text(String(format: "%.0f%%", gf))
                            }
                        }
                    }
                }
            } else if showSurfGf {
                AxisMarks(position: .trailing, values: .automatic) { value in
                    AxisValueLabel {
                        if let yVal = value.as(Float.self) {
                            let sgf = data.denormalizeSurfGf(yVal)
                            if sgf >= 0 {
                                Text(String(format: "%.0f%%", sgf))
                            }
                        }
                    }
                }
            } else if showTemperature {
                AxisMarks(position: .trailing, values: .automatic) { value in
                    AxisValueLabel {
                        if let yVal = value.as(Float.self) {
                            let temp = data.denormalizeTemp(yVal)
                            Text(String(format: "%.1f%@", temp, UnitFormatter.temperatureLabel(temperatureUnit)))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chartAccessibilityLabel)
    }

    // MARK: - Readout Bar

    private var readoutBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: isFullscreen ? 12 : 8) {
                if let depthStr = selectedDepthDisplay {
                    Text(depthStr)
                        .fontWeight(.semibold)
                }
                if let timeStr = selectedElapsedTime {
                    Text(timeStr)
                        .foregroundColor(.secondary)
                }
                if let gasStr = selectedGasDisplay {
                    Text(gasStr)
                        .foregroundColor(.mint)
                }
                if let spStr = selectedSetpointDisplay {
                    Text(spStr)
                        .foregroundColor(.pink)
                }
                if let tempStr = selectedTempDisplay {
                    Text(tempStr)
                        .foregroundColor(.orange)
                }
                if let ceilStr = selectedCeilingDisplay {
                    Text("CEIL \(ceilStr)")
                        .foregroundColor(.red)
                }
                if let ttsStr = selectedTtsDisplay {
                    Text("TTS \(ttsStr)")
                        .foregroundColor(.red)
                }
                if let ndlStr = selectedNdlDisplay {
                    Text("NDL \(ndlStr)")
                        .foregroundColor(.green)
                }
                if let gf99Str = selectedGf99Display {
                    Text("GF99 \(gf99Str)")
                        .foregroundColor(.purple)
                }
                if let atPlusFiveStr = selectedAtPlusFiveDisplay {
                    Text("@+5 \(atPlusFiveStr)")
                        .foregroundColor(.cyan)
                }
                if let deltaFiveStr = selectedDeltaFiveDisplay {
                    Text("\u{0394}+5 \(deltaFiveStr)")
                        .foregroundColor(.yellow)
                }
                if let surfGfStr = selectedSurfGfDisplay {
                    Text("SurfGF \(surfGfStr)")
                        .foregroundColor(.teal)
                }
            }
            .font(isFullscreen ? .caption : .caption2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(readoutBackground)
        .cornerRadius(6)
    }

    private var readoutBackground: some ShapeStyle {
        #if os(iOS)
        Color(.systemBackground).opacity(0.85)
        #else
        Color(.windowBackgroundColor).opacity(0.85)
        #endif
    }

    private var annotationBackground: some ShapeStyle {
        #if os(iOS)
        Color(.systemBackground).opacity(0.75)
        #else
        Color(.windowBackgroundColor).opacity(0.75)
        #endif
    }

    // MARK: - Helpers

    private func buildChartData() {
        chartData = DepthProfileChartData(
            samples: samples,
            depthUnit: depthUnit,
            temperatureUnit: temperatureUnit,
            gasMixes: gasMixes,
            needsSurfGf: showSurfGf
        )
    }
}

// MARK: - Data point types

struct DepthDataPoint: Identifiable {
    let id: Int
    let timeMinutes: Float
    /// Positive depth value for display (tooltip, accessibility).
    let depth: Float
}

struct TempDataPoint: Identifiable {
    let id: Int
    let timeMinutes: Float
    /// Negative normalized value for chart Y axis.
    let normalizedValue: Float
}

struct CeilingDataPoint: Identifiable {
    let id: Int
    let timeMinutes: Float
    /// Positive ceiling depth in display units.
    let ceilingDepth: Float
}

/// Shared data point type for all overlay series (GF99, @+5, Δ+5, SurfGF).
struct OverlayDataPoint: Identifiable {
    let id: Int
    let timeMinutes: Float
    /// Negative normalized value mapped to depth Y-axis.
    let normalizedValue: Float
}

struct GasSwitchMarker: Identifiable {
    let id: Int
    let timeMinutes: Float
    let gasLabel: String
    let color: Color
}

struct SetpointSwitchMarker: Identifiable {
    let id: Int
    let timeMinutes: Float
    let setpoint: Float
}
