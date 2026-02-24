import XCTest
@testable import DivelogCore

final class SampleCacheKeyTests: XCTestCase {

    // MARK: - Helpers

    private func makeSample(
        id: String = UUID().uuidString,
        diveId: String = "dive-1",
        deviceId: String? = nil,
        tSec: Int32 = 0
    ) -> DiveSample {
        DiveSample(
            id: id,
            diveId: diveId,
            deviceId: deviceId,
            tSec: tSec,
            depthM: 30.0,
            tempC: 20.0
        )
    }

    // MARK: - Basic behavior

    func testEmptyArrayCacheKey() {
        let samples: [DiveSample] = []
        XCTAssertEqual(samples.cacheKey, "--0")
    }

    func testSingleSampleCacheKey() {
        let sample = makeSample(id: "abc")
        XCTAssertEqual([sample].cacheKey, "abc-abc-1")
    }

    func testStableForSameArray() {
        let samples = [
            makeSample(id: "a", tSec: 0),
            makeSample(id: "b", tSec: 10),
            makeSample(id: "c", tSec: 20),
        ]
        XCTAssertEqual(samples.cacheKey, samples.cacheKey)
    }

    // MARK: - Device switch detection (primary use case)

    func testDifferentDevicesSameCountProduceDifferentKeys() {
        let deviceA = [
            makeSample(id: "a1", deviceId: "shearwater", tSec: 0),
            makeSample(id: "a2", deviceId: "shearwater", tSec: 10),
            makeSample(id: "a3", deviceId: "shearwater", tSec: 20),
        ]
        let deviceB = [
            makeSample(id: "b1", deviceId: "garmin", tSec: 0),
            makeSample(id: "b2", deviceId: "garmin", tSec: 10),
            makeSample(id: "b3", deviceId: "garmin", tSec: 20),
        ]
        XCTAssertEqual(deviceA.count, deviceB.count)
        XCTAssertNotEqual(deviceA.cacheKey, deviceB.cacheKey)
    }

    // MARK: - Count changes

    func testDifferentCountProducesDifferentKey() {
        let two = [
            makeSample(id: "a", tSec: 0),
            makeSample(id: "b", tSec: 10),
        ]
        let three = [
            makeSample(id: "a", tSec: 0),
            makeSample(id: "x", tSec: 5),
            makeSample(id: "b", tSec: 10),
        ]
        // Same first and last IDs, different count
        XCTAssertNotEqual(two.cacheKey, three.cacheKey)
    }

    // MARK: - Interior-only changes (known limitation)

    func testInteriorChangeWithSameBoundariesNotDetected() {
        let original = [
            makeSample(id: "a", tSec: 0),
            makeSample(id: "b", tSec: 10),
            makeSample(id: "c", tSec: 20),
        ]
        let modified = [
            makeSample(id: "a", tSec: 0),
            makeSample(id: "d", tSec: 15),  // different interior sample
            makeSample(id: "c", tSec: 20),
        ]
        // Documented limitation: interior-only changes are not detected.
        // This is acceptable because device switches always change boundary IDs.
        XCTAssertEqual(original.cacheKey, modified.cacheKey,
                       "Interior changes are intentionally not detected by cacheKey")
    }

    // MARK: - Edge cases

    func testAppendChangesKey() {
        let before = [
            makeSample(id: "a", tSec: 0),
            makeSample(id: "b", tSec: 10),
        ]
        let after = before + [makeSample(id: "c", tSec: 20)]
        XCTAssertNotEqual(before.cacheKey, after.cacheKey)
    }

    func testPrependChangesKey() {
        let before = [
            makeSample(id: "b", tSec: 10),
            makeSample(id: "c", tSec: 20),
        ]
        let after = [makeSample(id: "a", tSec: 0)] + before
        XCTAssertNotEqual(before.cacheKey, after.cacheKey)
    }

    func testCompleteReplacementChangesKey() {
        let setA = [makeSample(id: "x")]
        let setB = [makeSample(id: "y")]
        XCTAssertNotEqual(setA.cacheKey, setB.cacheKey)
    }
}
