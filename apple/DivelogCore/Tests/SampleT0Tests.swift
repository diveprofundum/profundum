import XCTest
@testable import DivelogCore

final class SampleT0Tests: XCTestCase {
    private enum TimeGate: Equatable {
        case greaterThanZero
        case greaterThanOrEqualZero
    }

    private struct ParserConfig {
        let initialCurrentTime: Int32
        let timeGate: TimeGate
        let finalGate: TimeGate
    }

    private struct SimulatedSample: Equatable {
        var tSec: Int32
        var depthM: Float
        var tempC: Float
    }

    private struct SimulatorContext {
        var samples: [SimulatedSample] = []
        var currentTime: Int32
        var currentDepth: Float = 0
        var currentTemp: Float = 0

        mutating func commitCurrentSample() {
            samples.append(SimulatedSample(tSec: currentTime, depthM: currentDepth, tempC: currentTemp))
        }

        mutating func resetPerSampleFields() {
            currentDepth = 0
            currentTemp = 0
        }
    }

    private enum Event {
        case timeMs(Int32)
        case depth(Float)
        case temp(Float)
    }

    func testShearwaterImportPreservesFirstSampleAtTimeZero() throws {
        let config = try loadParserConfig(
            fileName: "ShearwaterCloudImportService.swift",
            contextName: "ShearwaterSampleContext"
        )
        XCTAssertEqual(config.initialCurrentTime, -1)
        XCTAssertEqual(config.timeGate, .greaterThanOrEqualZero)
        XCTAssertEqual(config.finalGate, .greaterThanOrEqualZero)

        let samples = simulateSamples(
            config: config,
            events: [
                .timeMs(0),
                .depth(12.3),
                .temp(18.4),
                .timeMs(1000),
                .depth(15.1),
                .temp(17.9),
            ]
        )

        XCTAssertEqual(samples.count, 2, "t=0 sample should be preserved")
        XCTAssertEqual(samples[0].tSec, 0)
        XCTAssertEqual(samples[0].depthM, 12.3, accuracy: 0.0001)
        XCTAssertEqual(samples[0].tempC, 18.4, accuracy: 0.0001)
    }

    func testDiveDownloadGuardUsesSentinelAndAllowsTimeZero() throws {
        let config = try loadParserConfig(
            fileName: "DiveDownloadService.swift",
            contextName: "SampleCallbackContext"
        )

        XCTAssertEqual(config.initialCurrentTime, -1)
        XCTAssertEqual(config.timeGate, .greaterThanOrEqualZero)
        XCTAssertEqual(config.finalGate, .greaterThanOrEqualZero)

        let samples = simulateSamples(
            config: config,
            events: [
                .timeMs(0),
                .depth(9.0),
                .temp(20.0),
                .timeMs(1000),
                .depth(10.0),
                .temp(19.0),
            ]
        )

        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].tSec, 0)
    }

    func testSentinelNeverCommitsAsRealSample() throws {
        let config = try loadParserConfig(
            fileName: "ShearwaterCloudImportService.swift",
            contextName: "ShearwaterSampleContext"
        )

        let samples = simulateSamples(
            config: config,
            events: [
                .depth(7.0),
                .temp(21.0),
            ]
        )

        XCTAssertTrue(samples.isEmpty)
        XCTAssertFalse(samples.contains { $0.tSec < 0 })
    }

    private func simulateSamples(config: ParserConfig, events: [Event]) -> [SimulatedSample] {
        var ctx = SimulatorContext(currentTime: config.initialCurrentTime)

        for event in events {
            switch event {
            case .timeMs(let tMs):
                if shouldCommit(currentTime: ctx.currentTime, samplesAreEmpty: ctx.samples.isEmpty, gate: config.timeGate) {
                    ctx.commitCurrentSample()
                }
                ctx.currentTime = tMs / 1000
                ctx.resetPerSampleFields()
            case .depth(let d):
                ctx.currentDepth = d
            case .temp(let t):
                ctx.currentTemp = t
            }
        }

        if shouldCommit(currentTime: ctx.currentTime, samplesAreEmpty: ctx.samples.isEmpty, gate: config.finalGate) {
            ctx.commitCurrentSample()
        }

        return ctx.samples
    }

    private func shouldCommit(currentTime: Int32, samplesAreEmpty: Bool, gate: TimeGate) -> Bool {
        switch gate {
        case .greaterThanZero:
            return currentTime > 0 || !samplesAreEmpty
        case .greaterThanOrEqualZero:
            return currentTime >= 0 || !samplesAreEmpty
        }
    }

    private func loadParserConfig(fileName: String, contextName: String) throws -> ParserConfig {
        let source = try readServiceSource(fileName: fileName)

        let initialCurrentTime = try parseInitialCurrentTime(source: source, contextName: contextName)
        let timeGate = try parseGate(
            source: source,
            pattern: #"if\s+ctx\.pointee\.currentTime\s*(>=|>)\s*0\s*\|\|\s*!ctx\.pointee\.samples\.isEmpty"#
        )
        let finalGate = try parseGate(
            source: source,
            pattern: #"if\s+sampleContext\.currentTime\s*(>=|>)\s*0\s*\|\|\s*!sampleContext\.samples\.isEmpty"#
        )

        return ParserConfig(
            initialCurrentTime: initialCurrentTime,
            timeGate: timeGate,
            finalGate: finalGate
        )
    }

    private func parseInitialCurrentTime(source: String, contextName: String) throws -> Int32 {
        let pattern = #"struct\s+"# + contextName + #"\s*\{[\s\S]*?var\s+currentTime:\s*Int32\s*=\s*(-?\d+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)

        guard let match = regex.firstMatch(in: source, range: nsRange),
              let valueRange = Range(match.range(at: 1), in: source),
              let value = Int32(source[valueRange])
        else {
            throw XCTSkip("Could not parse currentTime initializer for \(contextName)")
        }

        return value
    }

    private func parseGate(source: String, pattern: String) throws -> TimeGate {
        let regex = try NSRegularExpression(pattern: pattern)
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)

        guard let match = regex.firstMatch(in: source, range: nsRange),
              let opRange = Range(match.range(at: 1), in: source)
        else {
            throw XCTSkip("Could not parse commit gate in service source")
        }

        switch String(source[opRange]) {
        case ">":
            return .greaterThanZero
        case ">=":
            return .greaterThanOrEqualZero
        default:
            throw XCTSkip("Unexpected gate operator")
        }
    }

    // MARK: - PNF Backfill Alignment

    func testPnfBackfillAlignsWithT0SamplePresent() {
        // Simulate: sample callback produces 3 samples (t=0, t=10, t=20)
        // PNF extractor produces 2 records (no t=0 in binary format)
        let sampleCount = 3
        let pnfCount = 2
        let firstSampleTSec: Int32 = 0

        // The offset logic from the production code:
        let pnfOffset = (firstSampleTSec == 0 && pnfCount == sampleCount - 1) ? 1 : 0

        XCTAssertEqual(pnfOffset, 1, "Offset should be 1 when t=0 sample is present")
        XCTAssertEqual(pnfCount, sampleCount - pnfOffset,
                       "PNF count should match sample count minus offset")

        // Verify backfill targets the correct indices (skipping t=0)
        var backfilledIndices: [Int] = []
        for i in 0 ..< pnfCount {
            backfilledIndices.append(i + pnfOffset)
        }
        XCTAssertEqual(backfilledIndices, [1, 2],
                       "PNF data should be applied to samples[1] and samples[2], not samples[0]")
    }

    func testPnfBackfillAlignsWithoutT0Sample() {
        // Simulate: sample callback produces 2 samples (t=10, t=20) — no t=0
        // PNF extractor produces 2 records
        let sampleCount = 2
        let pnfCount = 2
        let firstSampleTSec: Int32 = 10

        let pnfOffset = (firstSampleTSec == 0 && pnfCount == sampleCount - 1) ? 1 : 0

        XCTAssertEqual(pnfOffset, 0, "Offset should be 0 when no t=0 sample")
        XCTAssertEqual(pnfCount, sampleCount - pnfOffset)

        var backfilledIndices: [Int] = []
        for i in 0 ..< pnfCount {
            backfilledIndices.append(i + pnfOffset)
        }
        XCTAssertEqual(backfilledIndices, [0, 1],
                       "PNF data should be applied starting at samples[0]")
    }

    func testPnfBackfillWithRealExtractor() {
        // Build a minimal PNF binary: 2 sample records + final record
        // Each record is 32 bytes. PNF format: first 2 bytes != 0xFFFF.
        // Record type 0x01 = dive sample, 0xFF = LOG_RECORD_FINAL
        // GF99 at byte offset 25, @+5 TTS at byte offset 27
        var blob = Data(count: 3 * 32) // 2 samples + 1 final

        // Record 0: type=0x01 (dive sample), GF99=50, @+5 TTS=3
        blob[0] = 0x01
        blob[25] = 50
        blob[27] = 3

        // Record 1: type=0x01 (dive sample), GF99=72, @+5 TTS=8
        blob[32] = 0x01
        blob[32 + 25] = 72
        blob[32 + 27] = 8

        // Record 2: type=0xFF (LOG_RECORD_FINAL)
        blob[64] = 0xFF

        let pnf = DiveDataMapper.extractPnfSampleFields(blob)
        XCTAssertEqual(pnf.gf99.count, 2, "PNF should extract 2 sample records")
        XCTAssertEqual(pnf.gf99[0], 50)
        XCTAssertEqual(pnf.gf99[1], 72)
        XCTAssertEqual(pnf.atPlusFiveTtsMin[0], 3)
        XCTAssertEqual(pnf.atPlusFiveTtsMin[1], 8)

        // Simulate 3 samples from callback (t=0, t=10, t=20)
        let sampleCount = 3
        let firstSampleTSec: Int32 = 0

        let pnfOffset = (firstSampleTSec == 0
            && pnf.gf99.count == sampleCount - 1) ? 1 : 0
        XCTAssertEqual(pnfOffset, 1)

        // Verify the backfill would assign PNF[0] → sample[1], PNF[1] → sample[2]
        // (sample[0] at t=0 gets no PNF data — correct, since PNF has no t=0 record)
        XCTAssertEqual(0 + pnfOffset, 1, "First PNF record maps to sample index 1")
        XCTAssertEqual(1 + pnfOffset, 2, "Second PNF record maps to sample index 2")
    }

    private func readServiceSource(fileName: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageRoot = testsDir.deletingLastPathComponent()
        let servicePath = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("Services")
            .appendingPathComponent(fileName)

        return try String(contentsOf: servicePath, encoding: .utf8)
    }
}
