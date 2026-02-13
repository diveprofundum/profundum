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
    let gf99Points: [Gf99DataPoint]

    let hasAtPlusFiveData: Bool
    let atPlusFiveDisplayRange: (min: Float, max: Float)?
    let atPlusFivePoints: [AtPlusFiveTtsDataPoint]

    let hasDeltaFiveData: Bool
    let deltaFiveDisplayRange: (min: Float, max: Float)?
    let deltaFivePoints: [DeltaFiveTtsDataPoint]

    let hasSurfGfData: Bool
    let surfGfDisplayRange: (min: Float, max: Float)?
    let surfGfPoints: [SurfGfDataPoint]
    /// SurfGF lookup by sample tSec for tooltip display.
    let surfGfLookup: [Int32: Float]

    init(samples: [DiveSample], depthUnit: DepthUnit, temperatureUnit: TemperatureUnit, gasMixes: [GasMix] = []) {
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

        // GF99 pass: downsample + smooth, normalize to depth Y-axis (same pattern as temperature).
        let anyGf99 = samples.contains { ($0.gf99 ?? 0) > 0 }
        self.hasGf99Data = anyGf99
        if anyGf99 {
            var minGf: Float = .greatestFiniteMagnitude
            var maxGf: Float = -.greatestFiniteMagnitude
            for s in samples {
                if let g = s.gf99, g > 0 {
                    if g < minGf { minGf = g }
                    if g > maxGf { maxGf = g }
                }
            }
            let gfSpan = maxGf - minGf
            let gfPad = gfSpan > 0.1 ? gfSpan * 0.15 : max(minGf * 0.1, 1)
            let gfRange = (min: minGf - gfPad, max: maxGf + gfPad)
            let gfRangeDelta = gfRange.max - gfRange.min
            self.gf99DisplayRange = gfRange

            let gfTargetCount = 300
            let gfStride = max(1, samples.count / gfTargetCount)
            let gfHalfWindow = max(5, samples.count / 40)
            var gf99Pts: [Gf99DataPoint] = []
            gf99Pts.reserveCapacity(gfTargetCount + 2)
            var gi = 0
            var gfIdx = 0
            while gi < samples.count {
                let t = Float(samples[gi].tSec) / 60.0
                let wStart = max(0, gi - gfHalfWindow)
                let wEnd = min(samples.count - 1, gi + gfHalfWindow)
                var gfSum: Float = 0
                var gfCount = 0
                for j in wStart ... wEnd {
                    if let g = samples[j].gf99, g > 0 {
                        gfSum += g
                        gfCount += 1
                    }
                }
                if gfCount > 0 {
                    let avgGf = gfSum / Float(gfCount)
                    let fraction = (avgGf - gfRange.min) / gfRangeDelta
                    let normalized = -(maxD * (1.0 - fraction))
                    gf99Pts.append(Gf99DataPoint(id: gfIdx, timeMinutes: t, normalizedValue: normalized))
                    gfIdx += 1
                }
                gi += gfStride
            }
            // Always include last sample
            if let last = samples.last, let g = last.gf99, g > 0 {
                let lastT = Float(last.tSec) / 60.0
                if gf99Pts.last?.timeMinutes != lastT {
                    let fraction = (g - gfRange.min) / gfRangeDelta
                    let normalized = -(maxD * (1.0 - fraction))
                    gf99Pts.append(Gf99DataPoint(id: gfIdx, timeMinutes: lastT, normalizedValue: normalized))
                }
            }
            self.gf99Points = gf99Pts
        } else {
            self.gf99DisplayRange = nil
            self.gf99Points = []
        }

        // @+5 TTS pass: downsample + smooth + normalize (same pattern as GF99).
        let anyAtPlusFive = samples.contains { $0.atPlusFiveTtsMin != nil }
        self.hasAtPlusFiveData = anyAtPlusFive
        if anyAtPlusFive {
            var minVal: Float = .greatestFiniteMagnitude
            var maxVal: Float = -.greatestFiniteMagnitude
            for s in samples {
                if let v = s.atPlusFiveTtsMin {
                    let f = Float(v)
                    if f < minVal { minVal = f }
                    if f > maxVal { maxVal = f }
                }
            }
            let span = maxVal - minVal
            let pad = span > 0.1 ? span * 0.15 : max(minVal * 0.1, 1)
            let range = (min: minVal - pad, max: maxVal + pad)
            let rangeDelta = range.max - range.min
            self.atPlusFiveDisplayRange = range

            let targetCount = 300
            let stride = max(1, samples.count / targetCount)
            let halfWindow = max(5, samples.count / 40)
            var pts: [AtPlusFiveTtsDataPoint] = []
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
                    if let v = samples[j].atPlusFiveTtsMin {
                        sum += Float(v)
                        count += 1
                    }
                }
                if count > 0 {
                    let avg = sum / Float(count)
                    let fraction = (avg - range.min) / rangeDelta
                    let normalized = -(maxD * (1.0 - fraction))
                    pts.append(AtPlusFiveTtsDataPoint(id: idx, timeMinutes: t, normalizedValue: normalized))
                    idx += 1
                }
                si += stride
            }
            if let last = samples.last, let v = last.atPlusFiveTtsMin {
                let lastT = Float(last.tSec) / 60.0
                if pts.last?.timeMinutes != lastT {
                    let fraction = (Float(v) - range.min) / rangeDelta
                    let normalized = -(maxD * (1.0 - fraction))
                    pts.append(AtPlusFiveTtsDataPoint(id: idx, timeMinutes: lastT, normalizedValue: normalized))
                }
            }
            self.atPlusFivePoints = pts
        } else {
            self.atPlusFiveDisplayRange = nil
            self.atPlusFivePoints = []
        }

        // Δ+5 TTS pass: same pattern, source = deltaFiveTtsMin (can be negative).
        let anyDeltaFive = samples.contains { $0.deltaFiveTtsMin != nil }
        self.hasDeltaFiveData = anyDeltaFive
        if anyDeltaFive {
            var minVal: Float = .greatestFiniteMagnitude
            var maxVal: Float = -.greatestFiniteMagnitude
            for s in samples {
                if let v = s.deltaFiveTtsMin {
                    let f = Float(v)
                    if f < minVal { minVal = f }
                    if f > maxVal { maxVal = f }
                }
            }
            let span = maxVal - minVal
            let pad = span > 0.1 ? span * 0.15 : max(abs(minVal) * 0.1, 1)
            let range = (min: minVal - pad, max: maxVal + pad)
            let rangeDelta = range.max - range.min
            self.deltaFiveDisplayRange = range

            let targetCount = 300
            let stride = max(1, samples.count / targetCount)
            let halfWindow = max(5, samples.count / 40)
            var pts: [DeltaFiveTtsDataPoint] = []
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
                    if let v = samples[j].deltaFiveTtsMin {
                        sum += Float(v)
                        count += 1
                    }
                }
                if count > 0 {
                    let avg = sum / Float(count)
                    let fraction = (avg - range.min) / rangeDelta
                    let normalized = -(maxD * (1.0 - fraction))
                    pts.append(DeltaFiveTtsDataPoint(id: idx, timeMinutes: t, normalizedValue: normalized))
                    idx += 1
                }
                si += stride
            }
            if let last = samples.last, let v = last.deltaFiveTtsMin {
                let lastT = Float(last.tSec) / 60.0
                if pts.last?.timeMinutes != lastT {
                    let fraction = (Float(v) - range.min) / rangeDelta
                    let normalized = -(maxD * (1.0 - fraction))
                    pts.append(DeltaFiveTtsDataPoint(id: idx, timeMinutes: lastT, normalizedValue: normalized))
                }
            }
            self.deltaFivePoints = pts
        } else {
            self.deltaFiveDisplayRange = nil
            self.deltaFivePoints = []
        }

        // SurfGF pass: compute via Rust Bühlmann simulation, then downsample + normalize.
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

        // Build lookup by tSec for joining with samples (also stored for tooltip use)
        var surfGfLookupLocal: [Int32: Float] = [:]
        for pt in surfGfResult {
            surfGfLookupLocal[pt.tSec] = pt.surfaceGf
        }
        self.surfGfLookup = surfGfLookupLocal

        let anySurfGf = surfGfResult.contains { $0.surfaceGf > 0.1 }
        self.hasSurfGfData = anySurfGf
        if anySurfGf {
            var minSgf: Float = .greatestFiniteMagnitude
            var maxSgf: Float = -.greatestFiniteMagnitude
            for pt in surfGfResult where pt.surfaceGf > 0.1 {
                if pt.surfaceGf < minSgf { minSgf = pt.surfaceGf }
                if pt.surfaceGf > maxSgf { maxSgf = pt.surfaceGf }
            }
            let span = maxSgf - minSgf
            let pad = span > 0.1 ? span * 0.15 : max(minSgf * 0.1, 1)
            let range = (min: minSgf - pad, max: maxSgf + pad)
            let rangeDelta = range.max - range.min
            self.surfGfDisplayRange = range

            let targetCount = 300
            let stride = max(1, samples.count / targetCount)
            let halfWindow = max(5, samples.count / 40)
            var pts: [SurfGfDataPoint] = []
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
                    if let sgf = surfGfLookupLocal[samples[j].tSec], sgf > 0.1 {
                        sum += sgf
                        count += 1
                    }
                }
                if count > 0 {
                    let avg = sum / Float(count)
                    let fraction = (avg - range.min) / rangeDelta
                    let normalized = -(maxD * (1.0 - fraction))
                    pts.append(SurfGfDataPoint(id: idx, timeMinutes: t, normalizedValue: normalized))
                    idx += 1
                }
                si += stride
            }
            if let last = samples.last, let sgf = surfGfLookupLocal[last.tSec], sgf > 0.1 {
                let lastT = Float(last.tSec) / 60.0
                if pts.last?.timeMinutes != lastT {
                    let fraction = (sgf - range.min) / rangeDelta
                    let normalized = -(maxD * (1.0 - fraction))
                    pts.append(SurfGfDataPoint(id: idx, timeMinutes: lastT, normalizedValue: normalized))
                }
            }
            self.surfGfPoints = pts
        } else {
            self.surfGfDisplayRange = nil
            self.surfGfPoints = []
        }
    }

    /// Padded Y domain bounds (negative depth scale).
    var domainMin: Float { -(maxDepth * 1.15) }
    var domainMax: Float { maxDepth * 0.05 }

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
    func nearestSurfGfDisplay(to time: Float, samples: [DiveSample], surfGfLookup: [Int32: Float]) -> String? {
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
        return data.nearestSurfGfDisplay(to: selectedTime, samples: samples, surfGfLookup: data.surfGfLookup)
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
        return label
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let data = chartData {
                chartContent(data: data)
            } else {
                Color.clear
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
        .overlay(alignment: .top) {
            if selectedTime != nil {
                readoutBar
                    .offset(y: -24)
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

    // MARK: - Helpers

    private func buildChartData() {
        chartData = DepthProfileChartData(
            samples: samples,
            depthUnit: depthUnit,
            temperatureUnit: temperatureUnit,
            gasMixes: gasMixes
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

struct Gf99DataPoint: Identifiable {
    let id: Int
    let timeMinutes: Float
    /// Negative normalized value mapped to depth Y-axis.
    let normalizedValue: Float
}

struct AtPlusFiveTtsDataPoint: Identifiable {
    let id: Int
    let timeMinutes: Float
    let normalizedValue: Float
}

struct DeltaFiveTtsDataPoint: Identifiable {
    let id: Int
    let timeMinutes: Float
    let normalizedValue: Float
}

struct SurfGfDataPoint: Identifiable {
    let id: Int
    let timeMinutes: Float
    let normalizedValue: Float
}
