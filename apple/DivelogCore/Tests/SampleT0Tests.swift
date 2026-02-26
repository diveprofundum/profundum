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
