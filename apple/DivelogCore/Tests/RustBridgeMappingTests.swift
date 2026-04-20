import XCTest
@testable import DivelogCore

final class RustBridgeMappingTests: XCTestCase {

    // MARK: - DiveSample.toSampleInputs()

    func testToSampleInputsEmpty() {
        let samples: [DiveSample] = []
        let result = samples.toSampleInputs()
        XCTAssertTrue(result.isEmpty)
    }

    func testToSampleInputsBasicMapping() {
        let samples = [
            DiveSample(
                diveId: "d1",
                tSec: 100,
                depthM: 30.5,
                tempC: 18.0,
                setpointPpo2: 1.2,
                ceilingM: 3.0,
                gf99: 85.0,
                ppo2_1: 1.15,
                ttsSec: 600,
                ndlSec: nil,
                decoStopDepthM: 6.0,
                gasmixIndex: 2,
                atPlusFiveTtsMin: 12
            ),
        ]
        let result = samples.toSampleInputs()
        XCTAssertEqual(result.count, 1)
        let s = result[0]
        XCTAssertEqual(s.tSec, 100)
        XCTAssertEqual(s.depthM, 30.5)
        XCTAssertEqual(s.tempC, 18.0)
        XCTAssertEqual(s.setpointPpo2, 1.2)
        XCTAssertEqual(s.ceilingM, 3.0)
        XCTAssertEqual(s.gf99, 85.0)
        XCTAssertEqual(s.gasmixIndex, 2)
        // ppo2 should prefer ppo2_1 over setpointPpo2
        XCTAssertEqual(s.ppo2, 1.15)
        XCTAssertEqual(s.ttsSec, 600)
        XCTAssertNil(s.ndlSec)
        XCTAssertEqual(s.decoStopDepthM, 6.0)
        XCTAssertEqual(s.atPlusFiveTtsMin, 12)
    }

    func testToSampleInputsPpo2FallsBackToSetpoint() {
        // When ppo2_1 is nil, ppo2 should fall back to setpointPpo2
        let samples = [
            DiveSample(
                diveId: "d1",
                tSec: 0,
                depthM: 10.0,
                tempC: 20.0,
                setpointPpo2: 1.3,
                ppo2_1: nil
            ),
        ]
        let result = samples.toSampleInputs()
        XCTAssertEqual(result[0].ppo2, 1.3)
    }

    func testToSampleInputsPpo2NilWhenBothNil() {
        // When both ppo2_1 and setpointPpo2 are nil, ppo2 should be nil (OC dive)
        let samples = [
            DiveSample(
                diveId: "d1",
                tSec: 0,
                depthM: 10.0,
                tempC: 20.0
            ),
        ]
        let result = samples.toSampleInputs()
        XCTAssertNil(result[0].ppo2)
    }

    func testToSampleInputsMultipleSamples() {
        let samples = [
            DiveSample(diveId: "d1", tSec: 0, depthM: 0.0, tempC: 20.0),
            DiveSample(diveId: "d1", tSec: 120, depthM: 30.0, tempC: 18.0),
            DiveSample(diveId: "d1", tSec: 1200, depthM: 30.0, tempC: 17.5),
            DiveSample(diveId: "d1", tSec: 1800, depthM: 0.0, tempC: 20.0),
        ]
        let result = samples.toSampleInputs()
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0].tSec, 0)
        XCTAssertEqual(result[1].depthM, 30.0)
        XCTAssertEqual(result[2].tSec, 1200)
        XCTAssertEqual(result[3].depthM, 0.0)
    }

    func testToSampleInputsGasmixIndexConversion() {
        // gasmixIndex is Int in DiveSample, Int32 in SampleInput
        let samples = [
            DiveSample(diveId: "d1", tSec: 0, depthM: 10.0, tempC: 20.0, gasmixIndex: 0),
            DiveSample(diveId: "d1", tSec: 60, depthM: 10.0, tempC: 20.0, gasmixIndex: 1),
            DiveSample(diveId: "d1", tSec: 120, depthM: 10.0, tempC: 20.0), // nil gasmixIndex
        ]
        let result = samples.toSampleInputs()
        XCTAssertEqual(result[0].gasmixIndex, 0)
        XCTAssertEqual(result[1].gasmixIndex, 1)
        XCTAssertNil(result[2].gasmixIndex)
    }

    // MARK: - GasMix.toGasMixInputs()

    func testToGasMixInputsEmpty() {
        let mixes: [GasMix] = []
        let result = mixes.toGasMixInputs()
        XCTAssertTrue(result.isEmpty)
    }

    func testToGasMixInputsBasicMapping() {
        let mixes = [
            GasMix(diveId: "d1", mixIndex: 0, o2Fraction: 0.21, heFraction: 0.35),
            GasMix(diveId: "d1", mixIndex: 1, o2Fraction: 0.50, heFraction: 0.0),
        ]
        let result = mixes.toGasMixInputs()
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].mixIndex, 0)
        XCTAssertEqual(result[0].o2Fraction, 0.21, accuracy: 0.001)
        XCTAssertEqual(result[0].heFraction, 0.35, accuracy: 0.001)
        XCTAssertEqual(result[1].mixIndex, 1)
        XCTAssertEqual(result[1].o2Fraction, 0.50, accuracy: 0.001)
        XCTAssertEqual(result[1].heFraction, 0.0, accuracy: 0.001)
    }

    func testToGasMixInputsTypeConversion() {
        // mixIndex is Int in GasMix, Int32 in GasMixInput
        // o2/he are Float in GasMix, Double in GasMixInput
        let mixes = [
            GasMix(diveId: "d1", mixIndex: 3, o2Fraction: 0.18, heFraction: 0.45),
        ]
        let result = mixes.toGasMixInputs()
        XCTAssertEqual(result[0].mixIndex, 3)
        // Float → Double precision should be close
        XCTAssertEqual(result[0].o2Fraction, Double(Float(0.18)), accuracy: 1e-6)
        XCTAssertEqual(result[0].heFraction, Double(Float(0.45)), accuracy: 1e-6)
    }

    // MARK: - ProfileGenResult.plannedStops (PRO-51)

    /// A shallow NDL dive must round-trip through the FFI with an empty
    /// `plannedStops` array — exercising the new field on the no-deco path.
    func testGenerateDiveProfileShallowHasNoPlannedStops() throws {
        let params = ProfileGenParams(
            targetDepthM: 12.0,
            bottomTimeSec: 1800,
            descentRateMMin: nil,
            ascentRateMMin: nil,
            gasPlan: [],
            model: .buhlmannZhl16c,
            surfacePressureBar: nil,
            gfLow: nil,
            gfHigh: nil,
            lastStopDepthM: nil,
            stopIntervalM: nil,
            setpointPpo2: nil,
            thalmannPdcs: nil,
            sampleIntervalSec: nil,
            tempC: nil
        )
        let result = try DivelogCompute.generateDiveProfile(params: params)
        XCTAssertTrue(result.plannedStops.isEmpty,
                      "Shallow NDL dive should produce no planned stops")
    }

    /// A deep air dive with conservative GFs must populate `plannedStops`
    /// across the FFI boundary with valid depth/duration and deepest-first
    /// ordering — guards against regressions in the UniFFI field mapping
    /// introduced in PRO-51.
    func testGenerateDiveProfilePlannedStopsRoundTrip() throws {
        let params = ProfileGenParams(
            targetDepthM: 40.0,
            bottomTimeSec: 1200,
            descentRateMMin: nil,
            ascentRateMMin: nil,
            gasPlan: [],
            model: .buhlmannZhl16c,
            surfacePressureBar: nil,
            gfLow: 50,
            gfHigh: 80,
            lastStopDepthM: nil,
            stopIntervalM: nil,
            setpointPpo2: nil,
            thalmannPdcs: nil,
            sampleIntervalSec: nil,
            tempC: nil
        )
        let result = try DivelogCompute.generateDiveProfile(params: params)

        XCTAssertFalse(result.plannedStops.isEmpty,
                       "Deep dive with conservative GFs should produce planned stops")

        for pair in zip(result.plannedStops, result.plannedStops.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0.depthM, pair.1.depthM,
                                        "plannedStops must be sorted deepest-first")
        }

        for stop in result.plannedStops {
            XCTAssertGreaterThan(stop.durationSec, 0,
                                 "Each planned stop must have a positive duration")
            XCTAssertGreaterThan(stop.depthM, 0,
                                 "Stop depth must be > 0")
            XCTAssertLessThan(stop.depthM, 40.0,
                              "Stop depth must be shallower than bottom")
        }
    }
}
