import XCTest
@testable import DivelogCore

/// Tests for ImportProgressTracker auto-stop logic.
final class ImportProgressTrackerTests: XCTestCase {

    func testAutoStopAfterConsecutiveSkips() {
        let tracker = ImportProgressTracker()

        for _ in 0..<9 {
            tracker.record(.skipped)
            XCTAssertFalse(tracker.shouldAutoStop)
        }

        tracker.record(.skipped)  // 10th consecutive skip
        XCTAssertTrue(tracker.shouldAutoStop)
        XCTAssertEqual(tracker.skipped, 10)
        XCTAssertEqual(tracker.consecutiveSkips, 10)
    }

    func testConsecutiveSkipResetsOnSave() {
        let tracker = ImportProgressTracker()

        // 9 skips
        for _ in 0..<9 {
            tracker.record(.skipped)
        }
        XCTAssertFalse(tracker.shouldAutoStop)

        // 1 save resets the counter
        tracker.record(.saved)
        XCTAssertEqual(tracker.consecutiveSkips, 0)

        // 9 more skips — still under threshold
        for _ in 0..<9 {
            tracker.record(.skipped)
        }
        XCTAssertFalse(tracker.shouldAutoStop)
        XCTAssertEqual(tracker.saved, 1)
        XCTAssertEqual(tracker.skipped, 18)
    }

    func testConsecutiveSkipResetsOnMerge() {
        let tracker = ImportProgressTracker()

        // 5 skips
        for _ in 0..<5 {
            tracker.record(.skipped)
        }

        // 1 merge resets the counter
        tracker.record(.merged)
        XCTAssertEqual(tracker.consecutiveSkips, 0)

        // 9 more skips — still under threshold
        for _ in 0..<9 {
            tracker.record(.skipped)
        }
        XCTAssertFalse(tracker.shouldAutoStop)
        XCTAssertEqual(tracker.merged, 1)
        XCTAssertEqual(tracker.skipped, 14)
    }

    func testResetConsecutiveSkipsPreservesTotals() {
        let tracker = ImportProgressTracker()

        tracker.record(.saved)
        tracker.record(.saved)
        for _ in 0..<5 {
            tracker.record(.skipped)
        }
        XCTAssertEqual(tracker.consecutiveSkips, 5)
        XCTAssertEqual(tracker.saved, 2)
        XCTAssertEqual(tracker.skipped, 5)

        tracker.resetConsecutiveSkips()
        XCTAssertEqual(tracker.consecutiveSkips, 0)
        XCTAssertFalse(tracker.shouldAutoStop)
        // Totals preserved
        XCTAssertEqual(tracker.saved, 2)
        XCTAssertEqual(tracker.skipped, 5)
    }

    func testCustomThreshold() {
        let tracker = ImportProgressTracker(consecutiveSkipThreshold: 5)

        for _ in 0..<4 {
            tracker.record(.skipped)
        }
        XCTAssertFalse(tracker.shouldAutoStop)

        tracker.record(.skipped)  // 5th
        XCTAssertTrue(tracker.shouldAutoStop)
        XCTAssertEqual(tracker.consecutiveSkips, 5)
    }

    /// PRO-70 / PRO-32: a save error is not a duplicate. With the lower
    /// 3-skip threshold, three persistence failures must not end the download.
    func testFailuresDoNotCountTowardAutoStop() {
        let tracker = ImportProgressTracker(consecutiveSkipThreshold: 3)

        for _ in 0..<5 {
            tracker.recordFailure()
        }
        XCTAssertEqual(tracker.failed, 5)
        XCTAssertEqual(tracker.skipped, 0)
        XCTAssertEqual(tracker.consecutiveSkips, 0)
        XCTAssertFalse(tracker.shouldAutoStop)
    }

    /// A failure in the middle of a skip run neither resets nor extends it.
    func testFailureLeavesConsecutiveSkipsUntouched() {
        let tracker = ImportProgressTracker(consecutiveSkipThreshold: 3)

        tracker.record(.skipped)
        tracker.record(.skipped)
        tracker.recordFailure()
        XCTAssertEqual(tracker.consecutiveSkips, 2)
        XCTAssertFalse(tracker.shouldAutoStop)

        tracker.record(.skipped)
        XCTAssertTrue(tracker.shouldAutoStop)
        XCTAssertEqual(tracker.failed, 1)
        XCTAssertEqual(tracker.skipped, 3)
    }
}
