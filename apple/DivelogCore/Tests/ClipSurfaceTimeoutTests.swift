import XCTest
@testable import DivelogCore

final class ClipSurfaceTimeoutTests: XCTestCase {

    // MARK: - Helpers

    private func makeSample(tSec: Int32, depthM: Float, tempC: Float = 20.0) -> ParsedSample {
        ParsedSample(tSec: tSec, depthM: depthM, tempC: tempC)
    }

    private func makeDive(
        startTimeUnix: Int64 = 1_000_000,
        bottomTimeSec: Int32 = 3600,
        samples: [ParsedSample] = []
    ) -> ParsedDive {
        let endTimeUnix = startTimeUnix + Int64(bottomTimeSec)
        return ParsedDive(
            startTimeUnix: startTimeUnix,
            endTimeUnix: endTimeUnix,
            maxDepthM: samples.map(\.depthM).max() ?? 30.0,
            avgDepthM: 15.0,
            bottomTimeSec: bottomTimeSec,
            samples: samples
        )
    }

    // MARK: - Tests

    func testNormalDiveWith10MinPadding() {
        // 30-min dive to 30m, then 10 min of surface padding at 0m
        var samples: [ParsedSample] = []
        // Descent + bottom + ascent (0–1800s, every 10s)
        for t in stride(from: 0, through: 1800, by: 10) {
            let depth: Float = t < 180 ? Float(t) / 6.0 : (t > 1620 ? Float(1800 - t) / 6.0 : 30.0)
            samples.append(makeSample(tSec: Int32(t), depthM: depth))
        }
        // Surface padding (1810–2400s at 0m)
        for t in stride(from: 1810, through: 2400, by: 10) {
            samples.append(makeSample(tSec: Int32(t), depthM: 0.0))
        }

        let dive = makeDive(bottomTimeSec: 2400, samples: samples)
        let clipped = DiveDataMapper.clipSurfaceTimeout(dive)

        // Last sample at depth >1m is at 1800s (depth 30m during the flat phase or ascent ending)
        // The last sample with depthM > 1.0 should be the clip point
        let lastDeepSample = samples.last(where: { $0.depthM > 1.0 })!
        XCTAssertEqual(clipped.bottomTimeSec, lastDeepSample.tSec)
        XCTAssertEqual(clipped.endTimeUnix, dive.startTimeUnix + Int64(lastDeepSample.tSec))
        XCTAssertTrue(clipped.samples.count < samples.count, "Padding samples should be removed")
        XCTAssertEqual(clipped.samples.last?.tSec, lastDeepSample.tSec)
    }

    func testMidDiveSurfaceIntervalPreserved() {
        // Dive with a mid-dive surface interval: dive → surface → dive → surface padding
        let samples: [ParsedSample] = [
            makeSample(tSec: 0, depthM: 0.0),
            makeSample(tSec: 60, depthM: 10.0),   // First descent
            makeSample(tSec: 300, depthM: 15.0),
            makeSample(tSec: 600, depthM: 0.5),   // Surface interval (below threshold)
            makeSample(tSec: 660, depthM: 0.3),   // Still at surface
            makeSample(tSec: 720, depthM: 12.0),  // Second descent
            makeSample(tSec: 1200, depthM: 20.0),
            makeSample(tSec: 1500, depthM: 5.0),  // Ascent
            makeSample(tSec: 1560, depthM: 2.0),  // Last sample > 1.0m
            makeSample(tSec: 1620, depthM: 0.0),  // Surface padding
            makeSample(tSec: 1680, depthM: 0.0),
            makeSample(tSec: 2100, depthM: 0.0),  // 10 min post-dive
        ]

        let dive = makeDive(bottomTimeSec: 2100, samples: samples)
        let clipped = DiveDataMapper.clipSurfaceTimeout(dive)

        // Should clip after the last sample > 1.0m (at t=1560, depth=2.0)
        XCTAssertEqual(clipped.samples.count, 9)
        XCTAssertEqual(clipped.bottomTimeSec, 1560)
        XCTAssertEqual(clipped.endTimeUnix, dive.startTimeUnix + 1560)
        // Mid-dive surface interval samples at t=600 and t=660 should still be present
        XCTAssertTrue(clipped.samples.contains(where: { $0.tSec == 600 }))
        XCTAssertTrue(clipped.samples.contains(where: { $0.tSec == 660 }))
    }

    func testNoPaddingReturnsUnchanged() {
        // Last sample is at depth — no padding to clip
        let samples: [ParsedSample] = [
            makeSample(tSec: 0, depthM: 0.0),
            makeSample(tSec: 60, depthM: 10.0),
            makeSample(tSec: 600, depthM: 20.0),
            makeSample(tSec: 1200, depthM: 5.0),  // Last sample, still at depth
        ]

        let dive = makeDive(bottomTimeSec: 1200, samples: samples)
        let clipped = DiveDataMapper.clipSurfaceTimeout(dive)

        XCTAssertEqual(clipped.samples.count, samples.count)
        XCTAssertEqual(clipped.bottomTimeSec, dive.bottomTimeSec)
        XCTAssertEqual(clipped.endTimeUnix, dive.endTimeUnix)
    }

    func testEmptySamplesReturnsUnchanged() {
        let dive = makeDive(samples: [])
        let clipped = DiveDataMapper.clipSurfaceTimeout(dive)

        XCTAssertTrue(clipped.samples.isEmpty)
        XCTAssertEqual(clipped.bottomTimeSec, dive.bottomTimeSec)
        XCTAssertEqual(clipped.endTimeUnix, dive.endTimeUnix)
    }

    func testAllSamplesBelowThreshold() {
        // Very shallow dive — all samples ≤ 1.0m
        let samples: [ParsedSample] = [
            makeSample(tSec: 0, depthM: 0.0),
            makeSample(tSec: 60, depthM: 0.5),
            makeSample(tSec: 120, depthM: 0.8),
            makeSample(tSec: 180, depthM: 1.0),  // Exactly at threshold, not above
            makeSample(tSec: 240, depthM: 0.3),
        ]

        let dive = makeDive(bottomTimeSec: 240, samples: samples)
        let clipped = DiveDataMapper.clipSurfaceTimeout(dive)

        // No sample > 1.0m, so returned as-is
        XCTAssertEqual(clipped.samples.count, samples.count)
        XCTAssertEqual(clipped.bottomTimeSec, dive.bottomTimeSec)
        XCTAssertEqual(clipped.endTimeUnix, dive.endTimeUnix)
    }

    func testEndTimeUnixRecalculation() {
        let startTime: Int64 = 1_700_000_000
        let samples: [ParsedSample] = [
            makeSample(tSec: 0, depthM: 0.0),
            makeSample(tSec: 120, depthM: 25.0),
            makeSample(tSec: 1800, depthM: 3.0),  // Last deep sample
            makeSample(tSec: 1860, depthM: 0.0),  // Padding
            makeSample(tSec: 2400, depthM: 0.0),  // More padding
        ]

        let dive = makeDive(startTimeUnix: startTime, bottomTimeSec: 2400, samples: samples)
        let clipped = DiveDataMapper.clipSurfaceTimeout(dive)

        XCTAssertEqual(clipped.endTimeUnix, startTime + 1800)
        XCTAssertEqual(clipped.bottomTimeSec, 1800)
    }

    func testBottomTimeSecRecalculation() {
        let samples: [ParsedSample] = [
            makeSample(tSec: 0, depthM: 0.0),
            makeSample(tSec: 10, depthM: 5.0),
            makeSample(tSec: 300, depthM: 30.0),
            makeSample(tSec: 900, depthM: 15.0),
            makeSample(tSec: 1200, depthM: 1.5),  // Last > 1.0m at t=1200
            makeSample(tSec: 1210, depthM: 0.8),
            makeSample(tSec: 1500, depthM: 0.0),
            makeSample(tSec: 1800, depthM: 0.0),
        ]

        let dive = makeDive(bottomTimeSec: 1800, samples: samples)
        let clipped = DiveDataMapper.clipSurfaceTimeout(dive)

        XCTAssertEqual(clipped.bottomTimeSec, 1200)
        XCTAssertEqual(clipped.samples.last?.tSec, 1200)
        XCTAssertEqual(clipped.samples.count, 5)
    }

    func testCustomThreshold() {
        let samples: [ParsedSample] = [
            makeSample(tSec: 0, depthM: 0.0),
            makeSample(tSec: 60, depthM: 5.0),
            makeSample(tSec: 600, depthM: 2.5),  // > 2.0m
            makeSample(tSec: 660, depthM: 1.5),  // > 1.0m but ≤ 2.0m
            makeSample(tSec: 720, depthM: 0.0),
        ]

        let dive = makeDive(bottomTimeSec: 720, samples: samples)

        // Default threshold (1.0m): clips after t=660
        let clippedDefault = DiveDataMapper.clipSurfaceTimeout(dive)
        XCTAssertEqual(clippedDefault.bottomTimeSec, 660)

        // Custom threshold (2.0m): clips after t=600
        let clippedCustom = DiveDataMapper.clipSurfaceTimeout(dive, surfaceThresholdM: 2.0)
        XCTAssertEqual(clippedCustom.bottomTimeSec, 600)
    }

    func testOtherFieldsPreserved() {
        let samples: [ParsedSample] = [
            makeSample(tSec: 0, depthM: 0.0),
            makeSample(tSec: 300, depthM: 20.0),
            makeSample(tSec: 600, depthM: 0.0),
        ]

        let dive = ParsedDive(
            startTimeUnix: 1_000_000,
            endTimeUnix: 1_000_600,
            maxDepthM: 20.0,
            avgDepthM: 10.0,
            bottomTimeSec: 600,
            isCcr: true,
            decoRequired: true,
            cnsPercent: 42.0,
            otu: 18.0,
            computerDiveNumber: 123,
            fingerprint: Data([0xDE, 0xAD]),
            samples: samples,
            minTempC: 12.0,
            maxTempC: 22.0,
            gfLow: 30,
            gfHigh: 70,
            decoModel: "buhlmann",
            gasMixes: [ParsedGasMix(index: 0, o2Fraction: 0.21, heFraction: 0.35)]
        )

        let clipped = DiveDataMapper.clipSurfaceTimeout(dive)

        // Verify non-time fields are preserved
        XCTAssertEqual(clipped.maxDepthM, 20.0)
        XCTAssertEqual(clipped.avgDepthM, 10.0)
        XCTAssertEqual(clipped.isCcr, true)
        XCTAssertEqual(clipped.decoRequired, true)
        XCTAssertEqual(clipped.cnsPercent, 42.0)
        XCTAssertEqual(clipped.otu, 18.0)
        XCTAssertEqual(clipped.computerDiveNumber, 123)
        XCTAssertEqual(clipped.fingerprint, Data([0xDE, 0xAD]))
        XCTAssertEqual(clipped.minTempC, 12.0)
        XCTAssertEqual(clipped.maxTempC, 22.0)
        XCTAssertEqual(clipped.gfLow, 30)
        XCTAssertEqual(clipped.gfHigh, 70)
        XCTAssertEqual(clipped.decoModel, "buhlmann")
        XCTAssertEqual(clipped.gasMixes.count, 1)
        XCTAssertEqual(clipped.startTimeUnix, 1_000_000)
    }
}
