import Foundation
import GRDB

/// Outcome of a single dive import attempt.
public enum ImportOutcome: Equatable, Sendable {
    /// New dive inserted.
    case saved
    /// Samples from a second computer added to an existing dive.
    case merged
    /// Duplicate — already have this device's data.
    case skipped
}

/// Tracks import progress and detects when auto-stop is appropriate.
///
/// ## Thread Safety
///
/// Marked `@unchecked Sendable`; all mutable state is guarded by `lock`.
/// Writes come from the persistence queue (`DivePersistenceQueue`) while the
/// libdivecomputer download thread and the retry loop read counters
/// concurrently, so every accessor takes the lock.
public final class ImportProgressTracker: @unchecked Sendable {
    public let consecutiveSkipThreshold: Int

    private let lock = NSLock()
    private var _saved = 0
    private var _merged = 0
    private var _skipped = 0
    private var _failed = 0
    private var _consecutiveSkips = 0

    public var saved: Int { lock.withLock { _saved } }
    public var merged: Int { lock.withLock { _merged } }
    public var skipped: Int { lock.withLock { _skipped } }
    /// Dives that were downloaded but could not be persisted (database error).
    /// These are neither duplicates nor successes and must not feed auto-stop.
    public var failed: Int { lock.withLock { _failed } }
    public var consecutiveSkips: Int { lock.withLock { _consecutiveSkips } }

    public init(consecutiveSkipThreshold: Int = 10) {
        self.consecutiveSkipThreshold = consecutiveSkipThreshold
    }

    public func record(_ outcome: ImportOutcome) {
        lock.withLock {
            switch outcome {
            case .saved:  _saved += 1; _consecutiveSkips = 0
            case .merged: _merged += 1; _consecutiveSkips = 0
            case .skipped: _skipped += 1; _consecutiveSkips += 1
            }
        }
    }

    /// Records a dive whose save threw. Leaves `consecutiveSkips` untouched so a
    /// run of persistence errors can never be mistaken for "all caught up" and
    /// silently end the download (PRO-32 / PRO-70).
    public func recordFailure() {
        lock.withLock { _failed += 1 }
    }

    public var shouldAutoStop: Bool {
        lock.withLock { _consecutiveSkips >= consecutiveSkipThreshold }
    }

    /// Resets the consecutive skip counter without losing accumulated totals.
    ///
    /// Called before a retry attempt so that re-enumerated (already-saved) dives
    /// don't trigger auto-stop prematurely.
    public func resetConsecutiveSkips() {
        lock.withLock { _consecutiveSkips = 0 }
    }
}

/// Persists downloaded dives on a dedicated serial queue so the
/// libdivecomputer callback can return immediately.
///
/// ## Why
///
/// `dc_device_foreach` delivers each dive on the download thread and does not
/// request the next dive until the callback returns. Halcyon Symbios devices
/// run their own host-response timer (they NAK with `ERR_TIMEOUT` and then drop
/// the link); parsing plus a multi-hundred-row GRDB write inside the callback
/// was long enough to trip it between dives (PRO-71). Handing the parsed dive
/// off here keeps BLE traffic flowing while the previous dive is written.
///
/// Saves stay strictly ordered (serial queue), so the newest-first enumeration
/// order and the fingerprint bookkeeping are unchanged. Call `drain()` before
/// reporting results so every enqueued dive has reached the database.
///
/// ## Thread Safety
///
/// `@unchecked Sendable`: the only mutable state is `pending`, guarded by the
/// serial `queue` (mutated only from blocks running on it) plus `lock` for the
/// cross-thread read in `pendingCount`.
public final class DivePersistenceQueue: @unchecked Sendable {
    private let importService: DiveComputerImportService
    private let tracker: ImportProgressTracker
    private let queue = DispatchQueue(label: "com.divelog.import.persist", qos: .userInitiated)
    private let lock = NSLock()
    private var _pending = 0
    /// Called on the queue after each save attempt, with the outcome or `nil` on error.
    private let onSaved: (@Sendable (ParsedDive, ImportOutcome?, Error?) -> Void)?

    /// Number of dives enqueued but not yet written.
    public var pendingCount: Int { lock.withLock { _pending } }

    public init(
        importService: DiveComputerImportService,
        tracker: ImportProgressTracker,
        onSaved: (@Sendable (ParsedDive, ImportOutcome?, Error?) -> Void)? = nil
    ) {
        self.importService = importService
        self.tracker = tracker
        self.onSaved = onSaved
    }

    /// Schedules `parsed` for persistence and returns immediately.
    public func enqueue(_ parsed: ParsedDive, deviceId: String) {
        lock.withLock { _pending += 1 }
        queue.async { [self] in
            defer { lock.withLock { _pending -= 1 } }
            do {
                let outcome = try importService.saveImportedDive(parsed, deviceId: deviceId)
                tracker.record(outcome)
                onSaved?(parsed, outcome, nil)
            } catch {
                tracker.recordFailure()
                onSaved?(parsed, nil, error)
            }
        }
    }

    /// Blocks until every dive enqueued so far has been written.
    ///
    /// Must not be called from `onSaved` (which runs on the persistence queue):
    /// that would deadlock. Use `drainAsync()` from async contexts.
    public func drain() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {}
    }

    /// Async variant of `drain()` that does not block the calling thread.
    public func drainAsync() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { cont.resume() }
        }
    }
}

/// A cancellation flag that can be set and polled from any thread.
///
/// Import cancellation is requested from several places at once: the UI
/// (MainActor), the persistence queue (auto-stop after consecutive duplicates),
/// and the libdivecomputer queue (cutoff-time check in `onDive`), and polled
/// by libdivecomputer through `onCancel`. A lock keeps all of that race-free.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _isSet = false

    public init() {}

    /// Whether cancellation has been requested.
    public var isSet: Bool { lock.withLock { _isSet } }

    /// Requests cancellation.
    public func set() { lock.withLock { _isSet = true } }

    /// Clears the flag, e.g. before a new attempt.
    public func reset() { lock.withLock { _isSet = false } }
}

/// Service for importing dives from a dive computer.
///
/// All libdivecomputer operations run on a dedicated serial queue,
/// never the Swift cooperative thread pool.
public final class DiveComputerImportService: Sendable {
    private let database: DivelogDatabase

    public init(database: DivelogDatabase) {
        self.database = database
    }

    /// Finds an existing dive by fingerprint, checking both the legacy `dives.fingerprint`
    /// column and the `dive_source_fingerprints` table.
    /// - Parameter fingerprint: The fingerprint blob from the dive computer.
    /// - Returns: The existing dive's ID if found, or `nil`.
    public func findExistingDiveByFingerprint(fingerprint: Data) throws -> String? {
        try database.dbQueue.read { db in
            try Self.findExistingDiveByFingerprint(fingerprint: fingerprint, db: db)
        }
    }

    /// Finds an existing dive from a different device whose time range overlaps.
    ///
    /// Times are compared in display-local space (raw + COALESCE(offset, 0)) so
    /// legacy local-as-UTC and real-UTC dives can match each other.
    /// - Parameters:
    ///   - localStartTime: The incoming dive's start in display-local time.
    ///   - localEndTime: The incoming dive's end in display-local time.
    ///   - deviceId: The device ID of the incoming dive (excluded from results).
    /// - Returns: The existing dive's ID if an overlapping dive from another device exists, or `nil`.
    public func findExistingDiveByOverlap(
        localStartTime: Int64, localEndTime: Int64, deviceId: String
    ) throws -> String? {
        try database.dbQueue.read { db in
            try Self.findExistingDiveByOverlap(
                localStartTime: localStartTime, localEndTime: localEndTime, deviceId: deviceId, db: db
            )
        }
    }

    /// Where a sync fingerprint came from, which determines how much we can trust
    /// libdivecomputer to recognise it.
    public enum FingerprintSource: Equatable, Sendable {
        /// Recorded by a BLE import — produced by libdivecomputer for this exact
        /// device, so it will match during incremental sync.
        case ble
        /// Legacy `dives.fingerprint` or a non-BLE `dive_source_fingerprints` row
        /// (e.g. Shearwater Cloud, whose fingerprints are UTF-8 dive IDs that
        /// libdivecomputer will never match). May be usable, may not.
        case legacy
    }

    /// Returns the most recent fingerprint for a given device, ordered by dive start time.
    ///
    /// Used for incremental sync: pass this fingerprint to libdivecomputer so it
    /// stops downloading once it reaches a dive we already have.
    ///
    /// Prefers fingerprints recorded by BLE imports (`dive_source_fingerprints`
    /// with `source_type = 'ble'`) because those are guaranteed to be in the
    /// format libdivecomputer produces. Falls back to the legacy
    /// `dives.fingerprint` column unioned with any other source-fingerprint rows,
    /// which covers dives BLE-imported before source rows were written but may
    /// also return a Cloud fingerprint the device cannot match.
    ///
    /// Both queries consider `dive_source_fingerprints`, not just `dives.fingerprint`.
    /// The latter belongs to the dive's *primary* device only, so a secondary
    /// computer whose dives were all merged into another device's dives was
    /// previously seen as having no fingerprint at all and re-downloaded
    /// everything on every import (PRO-70).
    /// - Parameter deviceId: The device to look up.
    /// - Returns: The newest fingerprint and where it came from, or `nil`.
    public func lastSyncFingerprint(deviceId: String) throws -> (fingerprint: Data, source: FingerprintSource)? {
        try database.dbQueue.read { db in
            if let ble = try Data.fetchOne(db, sql: """
                SELECT f.fingerprint
                FROM dive_source_fingerprints f
                JOIN dives d ON d.id = f.dive_id
                WHERE f.device_id = ? AND f.source_type = 'ble'
                ORDER BY d.start_time_unix DESC
                LIMIT 1
                """, arguments: [deviceId]) {
                return (ble, .ble)
            }
            if let legacy = try Data.fetchOne(db, sql: """
                SELECT fingerprint FROM (
                    SELECT d.fingerprint AS fingerprint, d.start_time_unix AS start_time_unix
                    FROM dives d
                    WHERE d.device_id = ? AND d.fingerprint IS NOT NULL
                    UNION ALL
                    SELECT f.fingerprint AS fingerprint, d.start_time_unix AS start_time_unix
                    FROM dive_source_fingerprints f
                    JOIN dives d ON d.id = f.dive_id
                    WHERE f.device_id = ?
                )
                ORDER BY start_time_unix DESC
                LIMIT 1
                """, arguments: [deviceId, deviceId]) {
                return (legacy, .legacy)
            }
            return nil
        }
    }

    /// Convenience over ``lastSyncFingerprint(deviceId:)`` returning only the bytes.
    public func lastFingerprint(deviceId: String) throws -> Data? {
        try lastSyncFingerprint(deviceId: deviceId)?.fingerprint
    }

    /// Saves an imported dive and its samples transactionally.
    ///
    /// Dedup strategy (in order):
    /// 1. **Fingerprint dedup** — checks both legacy `dives.fingerprint` and
    ///    `dive_source_fingerprints`. If matched:
    ///    - If the importing device already has samples → `.skipped`
    ///    - If both devices are owned (`.mine`) → merge samples → `.merged`
    ///    - Otherwise (buddy device) → fall through to new dive
    /// 2. **Time-overlap cross-source match** — if an owned dive from a
    ///    different device overlaps the incoming dive's time range:
    ///    - If the existing dive already has samples from this device → `.skipped`
    ///    - If both devices are owned → merge samples → `.merged`
    ///    - Otherwise → fall through to new dive
    /// 3. **New dive** — inserts dive, tags, samples, gas mixes, and a
    ///    `DiveSourceFingerprint` record → `.saved`.
    ///
    /// - Parameters:
    ///   - parsed: The parsed dive data from the dive computer.
    ///   - deviceId: The device ID to associate with the dive.
    /// - Returns: The import outcome (.saved, .merged, or .skipped).
    @discardableResult
    public func saveImportedDive(_ parsed: ParsedDive, deviceId: String) throws -> ImportOutcome {
        // Fast path: fingerprint-exact-match → skip only if this device already contributed samples
        if let fp = parsed.fingerprint,
           let existingDiveId = try findExistingDiveByFingerprint(fingerprint: fp) {
            if try hasSamplesFromDevice(diveId: existingDiveId, deviceId: deviceId) {
                try linkFingerprint(fp, deviceId: deviceId, toDiveId: existingDiveId)
                return .skipped
            }
            // Fall through — this device hasn't contributed samples.
            // Buddy devices will also fall through here and be handled by
            // shouldMergeDevices in the write transaction (creating a new dive).
        }

        // Prepare domain objects outside the write lock (pure mapping)
        let (dive, _, _) = DiveDataMapper.toDive(parsed, deviceId: deviceId)

        // Single write transaction handles merge, skip, and new-dive paths.
        // Fingerprint dedup is re-checked here (TOCTOU guard against the
        // read-only fast path above). Time-based merge/skip is checked only
        // here — no duplicate pre-check outside the transaction.
        return try database.dbQueue.write { db in
            // Re-check fingerprint (concurrent insert between fast path and write lock)
            if let fp = dive.fingerprint {
                if let existingDiveId = try Self.findExistingDiveByFingerprint(
                    fingerprint: fp, db: db
                ) {
                    if try Self.hasSamplesFromDevice(
                        diveId: existingDiveId, deviceId: deviceId, db: db
                    ) {
                        try Self.insertSourceFingerprint(
                            fp, deviceId: deviceId, diveId: existingDiveId, db: db
                        )
                        return .skipped
                    }
                    // Cross-device merge via fingerprint match
                    if try Self.shouldMergeDevices(
                        importingDeviceId: deviceId, existingDiveId: existingDiveId, db: db
                    ) {
                        try Self.mergeSamplesInTransaction(
                            parsed, deviceId: deviceId, intoDiveId: existingDiveId, db: db
                        )
                        return .merged
                    }
                    // Fall through — buddy device
                }
            }

            // Time-overlap cross-source match → merge or skip.
            // Normalize to display-local time so real-UTC and legacy dives can match.
            let localStart = parsed.startTimeUnix + Int64(parsed.timezoneOffsetSec ?? 0)
            let localEnd = parsed.endTimeUnix + Int64(parsed.timezoneOffsetSec ?? 0)
            if let fp = parsed.fingerprint,
               let existingDiveId = try Self.findExistingDiveByOverlap(
                   localStartTime: localStart,
                   localEndTime: localEnd,
                   deviceId: deviceId, db: db
               ) {
                if try Self.shouldMergeDevices(
                    importingDeviceId: deviceId, existingDiveId: existingDiveId, db: db
                ) {
                    if try Self.hasSamplesFromDevice(
                        diveId: existingDiveId, deviceId: deviceId, db: db
                    ) {
                        try Self.insertSourceFingerprint(
                            fp, deviceId: deviceId, diveId: existingDiveId, db: db
                        )
                        return .skipped
                    }
                    try Self.mergeSamplesInTransaction(
                        parsed, deviceId: deviceId, intoDiveId: existingDiveId, db: db
                    )
                    return .merged
                }
                // Fall through to new dive for buddy devices
            }

            // New dive
            try dive.insert(db)
            let typeTag = PredefinedDiveTag.diveTypeTag(isCcr: dive.isCcr)
            try DiveTag(diveId: dive.id, tag: typeTag.rawValue).insert(db)
            let activityTags = PredefinedDiveTag.autoActivityTags(
                isCcr: dive.isCcr, decoRequired: dive.decoRequired
            )
            for activityTag in activityTags {
                try DiveTag(diveId: dive.id, tag: activityTag.rawValue).insert(db)
            }

            let usedMixes = GasMixMergeHelper.filterUsedGasMixes(parsed.gasMixes, samples: parsed.samples)
            let indexRemap = try GasMixMergeHelper.mergeGasMixes(
                existingMixes: [],
                incomingMixes: usedMixes,
                diveId: dive.id,
                deviceId: deviceId,
                db: db
            )
            try GasMixMergeHelper.insertSamples(
                samples: parsed.samples,
                diveId: dive.id,
                deviceId: deviceId,
                indexRemap: indexRemap,
                db: db
            )
            try DiveDeviceSettings.upsert(
                diveId: dive.id,
                deviceId: deviceId,
                gfLow: parsed.gfLow,
                gfHigh: parsed.gfHigh,
                decoModel: parsed.decoModel,
                salinity: parsed.salinity,
                surfacePressureBar: parsed.surfacePressureBar,
                isPrimary: true,
                db: db
            )

            // Record BLE fingerprint in dive_source_fingerprints for future dedup
            if let fp = dive.fingerprint {
                try Self.insertSourceFingerprint(
                    fp, deviceId: deviceId, diveId: dive.id, db: db
                )
            }
            return .saved
        }
    }

    /// Saves multiple imported dives, skipping duplicates.
    /// - Parameters:
    ///   - parsedDives: The parsed dive data from the dive computer.
    ///   - deviceId: The device ID to associate with the dives.
    /// - Returns: The number of dives that were newly saved (not duplicates).
    public func saveImportedDives(_ parsedDives: [ParsedDive], deviceId: String) throws -> Int {
        var saved = 0
        for parsed in parsedDives where try saveImportedDive(parsed, deviceId: deviceId) == .saved {
            saved += 1
        }
        return saved
    }

    // MARK: - Merge Helpers

    /// Returns whether the given dive already has samples from the specified device.
    public func hasSamplesFromDevice(diveId: String, deviceId: String) throws -> Bool {
        try database.dbQueue.read { db in
            try Self.hasSamplesFromDevice(diveId: diveId, deviceId: deviceId, db: db)
        }
    }

    private static func hasSamplesFromDevice(diveId: String, deviceId: String, db: Database) throws -> Bool {
        try DiveSample
            .filter(Column("dive_id") == diveId)
            .filter(Column("device_id") == deviceId)
            .fetchCount(db) > 0
    }

    /// Core merge logic — must be called within a write transaction.
    private static func mergeSamplesInTransaction(
        _ parsed: ParsedDive, deviceId: String, intoDiveId existingDiveId: String, db: Database
    ) throws {
        let existingMixes = try GasMix
            .filter(Column("dive_id") == existingDiveId)
            .fetchAll(db)
        let usedMixes = GasMixMergeHelper.filterUsedGasMixes(parsed.gasMixes, samples: parsed.samples)
        let indexRemap = try GasMixMergeHelper.mergeGasMixes(
            existingMixes: existingMixes,
            incomingMixes: usedMixes,
            diveId: existingDiveId,
            deviceId: deviceId,
            db: db
        )
        try GasMixMergeHelper.insertSamples(
            samples: parsed.samples,
            diveId: existingDiveId,
            deviceId: deviceId,
            indexRemap: indexRemap,
            db: db
        )

        let isPrimary = try DiveDeviceSettings
            .filter(Column("dive_id") == existingDiveId)
            .fetchCount(db) == 0
        try DiveDeviceSettings.upsert(
            diveId: existingDiveId,
            deviceId: deviceId,
            gfLow: parsed.gfLow,
            gfHigh: parsed.gfHigh,
            decoModel: parsed.decoModel,
            salinity: parsed.salinity,
            surfacePressureBar: parsed.surfacePressureBar,
            isPrimary: isPrimary,
            db: db
        )

        // Link fingerprint
        if let fp = parsed.fingerprint {
            try Self.insertSourceFingerprint(fp, deviceId: deviceId, diveId: existingDiveId, db: db)
        }
    }

    // MARK: - Private Helpers

    /// Checks device ownership to determine if a merge is appropriate.
    /// Only merges when both the importing device and the existing dive's device are owned by the user.
    private static func shouldMergeDevices(
        importingDeviceId: String, existingDiveId: String, db: Database
    ) throws -> Bool {
        let importingOwnership = try Device.fetchOne(db, key: importingDeviceId)?.ownership ?? .mine
        guard importingOwnership != .other else { return false }
        let existingDive = try Dive.fetchOne(db, key: existingDiveId)
        let existingDeviceOwnership = try existingDive
            .flatMap { try Device.fetchOne(db, key: $0.deviceId) }?.ownership ?? .mine
        return existingDeviceOwnership == .mine
    }

    /// Checks both the legacy `dives.fingerprint` column and the `dive_source_fingerprints`
    /// table for a matching fingerprint. Returns the existing dive ID if found.
    private static func findExistingDiveByFingerprint(
        fingerprint: Data, db: Database
    ) throws -> String? {
        // Check legacy dives.fingerprint column
        if let dive = try Dive
            .filter(Column("fingerprint") == fingerprint)
            .fetchOne(db) {
            return dive.id
        }
        // Check dive_source_fingerprints table
        if let sourceFp = try DiveSourceFingerprint
            .filter(Column("fingerprint") == fingerprint)
            .fetchOne(db) {
            return sourceFp.diveId
        }
        return nil
    }

    /// Finds an existing dive from a different **owned** device whose time range
    /// overlaps the incoming dive.  Two dives overlap when each one starts before
    /// the other ends: `start_a < end_b AND start_b < end_a`.
    ///
    /// Times are compared in display-local space so that real-UTC dives
    /// (non-nil `timezone_offset_sec`) and legacy local-as-UTC dives (nil offset)
    /// can match each other.
    ///
    /// Only dives belonging to devices with `ownership = 'mine'` (or no device
    /// record, which defaults to owned) are considered.  This prevents a
    /// nondeterministic `LIMIT 1` from picking a buddy's dive when an owned dive
    /// also overlaps.
    ///
    /// Overlap matching is far more robust than a fixed start-time tolerance
    /// because different dive computers detect dive-start at different
    /// depths/times (observed >6 min skew between Shearwater Perdix 2 and
    /// Petrel 3 on the same dive).
    private static func findExistingDiveByOverlap(
        localStartTime: Int64, localEndTime: Int64, deviceId: String, db: Database
    ) throws -> String? {
        let row = try Row.fetchOne(db, sql: """
            SELECT dives.id FROM dives
            LEFT JOIN devices ON devices.id = dives.device_id
            WHERE (dives.start_time_unix + COALESCE(dives.timezone_offset_sec, 0)) < ?
              AND (dives.end_time_unix + COALESCE(dives.timezone_offset_sec, 0)) > ?
              AND dives.device_id != ?
              AND COALESCE(devices.ownership, 'mine') = 'mine'
            ORDER BY dives.start_time_unix ASC
            LIMIT 1
            """, arguments: [localEndTime, localStartTime, deviceId])
        return row?["id"] as String?
    }

    // MARK: - Split (Un-Merge)

    /// Errors that can occur during a dive split operation.
    public enum SplitError: Error, Equatable {
        case diveNotFound
        case notMerged
        case noSamplesForDevice
        case wouldRemoveAllSamples
    }

    /// Result of a successful dive split.
    public struct SplitResult: Sendable {
        public let newDiveId: String
        public let originalDiveId: String
    }

    /// Splits samples from `deviceId` out of a merged dive into a new dive.
    ///
    /// In a single write transaction:
    /// 1. Validates the dive exists, has multiple source devices, and the target
    ///    device has samples that wouldn't empty the original.
    /// 2. Creates the new dive with recomputed stats (must exist before FK refs).
    /// 3. Duplicates gas mixes referenced by the split samples to the new dive.
    /// 4. Moves samples (`dive_id` update) and remaps `gasmix_index`.
    /// 5. Moves fingerprints for the target device.
    /// 6. Copies tags to the new dive.
    /// 7. Recomputes stats and time range on the original dive.
    ///
    /// - Parameters:
    ///   - diveId: The merged dive to split.
    ///   - deviceId: The device whose samples should be extracted.
    /// - Returns: A `SplitResult` with the new and original dive IDs.
    public func splitDive(diveId: String, deviceId: String) throws -> SplitResult {
        try database.dbQueue.write { db in
            // 1. Validate
            guard let originalDive = try Dive.fetchOne(db, key: diveId) else {
                throw SplitError.diveNotFound
            }
            let allSamples = try DiveSample
                .filter(Column("dive_id") == diveId)
                .order(Column("t_sec"))
                .fetchAll(db)
            let sourceDeviceIds = Set(allSamples.compactMap(\.deviceId))
            guard sourceDeviceIds.count >= 2 else {
                throw SplitError.notMerged
            }
            let splitSamples = allSamples.filter { $0.deviceId == deviceId }
            guard !splitSamples.isEmpty else {
                throw SplitError.noSamplesForDevice
            }
            let remainingSamples = allSamples.filter { $0.deviceId != deviceId }
            guard !remainingSamples.isEmpty else {
                throw SplitError.wouldRemoveAllSamples
            }

            // 2. Create new dive with recomputed stats (must exist before FK references)
            let splitMixIndices = Set(splitSamples.compactMap(\.gasmixIndex))
            let existingMixes = try GasMix
                .filter(Column("dive_id") == diveId)
                .fetchAll(db)
            let newDiveId = UUID().uuidString
            let splitStats = Self.computeBasicStats(from: splitSamples)
            let newDive = Dive(
                id: newDiveId,
                deviceId: deviceId,
                startTimeUnix: originalDive.startTimeUnix + Int64(splitStats.startTSec),
                endTimeUnix: originalDive.startTimeUnix + Int64(splitStats.endTSec),
                maxDepthM: splitStats.maxDepthM,
                avgDepthM: splitStats.avgDepthM,
                bottomTimeSec: splitStats.bottomTimeSec,
                isCcr: originalDive.isCcr,
                decoRequired: originalDive.decoRequired,
                cnsPercent: originalDive.cnsPercent,
                otu: originalDive.otu,
                siteId: originalDive.siteId,
                notes: originalDive.notes,
                minTempC: splitStats.minTempC,
                maxTempC: splitStats.maxTempC,
                avgTempC: splitStats.avgTempC,
                gfLow: originalDive.gfLow,
                gfHigh: originalDive.gfHigh,
                decoModel: originalDive.decoModel,
                salinity: originalDive.salinity,
                surfacePressureBar: originalDive.surfacePressureBar,
                lat: originalDive.lat,
                lon: originalDive.lon,
                maxCeilingM: splitStats.maxCeilingM,
                environment: originalDive.environment,
                visibility: originalDive.visibility,
                weather: originalDive.weather,
                timezoneOffsetSec: originalDive.timezoneOffsetSec
            )
            try newDive.insert(db)

            // 3. Duplicate gas mixes referenced by split samples
            var indexRemap: [Int: Int] = [:]
            var newMixIndex = 0
            for mix in existingMixes where splitMixIndices.contains(mix.mixIndex) {
                indexRemap[mix.mixIndex] = newMixIndex
                try GasMix(
                    diveId: newDiveId,
                    mixIndex: newMixIndex,
                    o2Fraction: mix.o2Fraction,
                    heFraction: mix.heFraction,
                    usage: mix.usage,
                    deviceId: deviceId
                ).insert(db)
                newMixIndex += 1
            }

            // 4. Move samples — update dive_id and remap gasmixIndex
            for sample in splitSamples {
                let remappedIndex = sample.gasmixIndex.flatMap { indexRemap[$0] }
                try db.execute(
                    sql: """
                        UPDATE samples SET dive_id = ?, gasmix_index = ?
                        WHERE id = ?
                    """,
                    arguments: [newDiveId, remappedIndex, sample.id]
                )
            }

            // 5. Move fingerprints for this device
            try db.execute(
                sql: """
                    UPDATE dive_source_fingerprints
                    SET dive_id = ?
                    WHERE dive_id = ? AND device_id = ?
                """,
                arguments: [newDiveId, diveId, deviceId]
            )

            // 5b. Move this device's settings row to the new dive.
            // It becomes the only device on the new dive, so mark it primary.
            try db.execute(
                sql: """
                    UPDATE dive_device_settings
                    SET dive_id = ?, is_primary = 1
                    WHERE dive_id = ? AND device_id = ?
                """,
                arguments: [newDiveId, diveId, deviceId]
            )

            // 6. Copy tags
            let tags = try DiveTag
                .filter(Column("dive_id") == diveId)
                .fetchAll(db)
            for tag in tags {
                try DiveTag(diveId: newDiveId, tag: tag.tag).insert(db)
            }

            // 7. Recompute original dive stats from remaining samples.
            // If the split device was the primary, reassign device_id to a remaining source.
            let remainingStats = Self.computeBasicStats(from: remainingSamples)
            let remainingStartUnix = originalDive.startTimeUnix + Int64(remainingStats.startTSec)
            let remainingEndUnix = originalDive.startTimeUnix + Int64(remainingStats.endTSec)
            let newPrimaryDeviceId: String = {
                if originalDive.deviceId == deviceId {
                    // Primary device was split out — pick from remaining samples
                    return remainingSamples.first(where: { $0.deviceId != nil })?.deviceId
                        ?? originalDive.deviceId
                }
                return originalDive.deviceId
            }()
            try db.execute(
                sql: """
                    UPDATE dives SET
                        device_id = ?,
                        start_time_unix = ?,
                        end_time_unix = ?,
                        max_depth_m = ?,
                        avg_depth_m = ?,
                        bottom_time_sec = ?,
                        min_temp_c = ?,
                        max_temp_c = ?,
                        avg_temp_c = ?,
                        max_ceiling_m = ?
                    WHERE id = ?
                """,
                arguments: [
                    newPrimaryDeviceId,
                    remainingStartUnix,
                    remainingEndUnix,
                    remainingStats.maxDepthM,
                    remainingStats.avgDepthM,
                    remainingStats.bottomTimeSec,
                    remainingStats.minTempC,
                    remainingStats.maxTempC,
                    remainingStats.avgTempC,
                    remainingStats.maxCeilingM,
                    diveId
                ]
            )

            // If the split device was primary, promote the new primary's
            // settings row so the original dive keeps a primary device.
            if originalDive.deviceId == deviceId {
                try db.execute(
                    sql: """
                        UPDATE dive_device_settings
                        SET is_primary = 1
                        WHERE dive_id = ? AND device_id = ?
                    """,
                    arguments: [diveId, newPrimaryDeviceId]
                )
            }

            return SplitResult(newDiveId: newDiveId, originalDiveId: diveId)
        }
    }

    /// Basic stats computed from a set of samples (pure function).
    struct BasicStats {
        let startTSec: Int32
        let endTSec: Int32
        let maxDepthM: Float
        let avgDepthM: Float
        let bottomTimeSec: Int32
        let minTempC: Float?
        let maxTempC: Float?
        let avgTempC: Float?
        let maxCeilingM: Float?
    }

    static func computeBasicStats(from samples: [DiveSample]) -> BasicStats {
        guard !samples.isEmpty else {
            return BasicStats(
                startTSec: 0, endTSec: 0, maxDepthM: 0, avgDepthM: 0,
                bottomTimeSec: 0, minTempC: nil, maxTempC: nil, avgTempC: nil,
                maxCeilingM: nil
            )
        }
        let sorted = samples.sorted { $0.tSec < $1.tSec }
        // Safe: guard above ensures non-empty
        let startT = sorted[0].tSec
        let endT = sorted[sorted.count - 1].tSec
        let maxD = sorted.lazy.map(\.depthM).max() ?? 0
        let temps = sorted.map(\.tempC)
        let minT = temps.min()
        let maxT = temps.max()
        let avgT: Float? = temps.isEmpty ? nil : temps.reduce(0, +) / Float(temps.count)
        let maxCeiling: Float? = {
            let ceilings = sorted.compactMap(\.ceilingM).filter { $0 > 0 }
            return ceilings.max()
        }()

        // Time-weighted average depth
        var weightedSum: Float = 0
        var totalDt: Float = 0
        for i in 0..<(sorted.count - 1) {
            let dt = Float(sorted[i + 1].tSec - sorted[i].tSec)
            guard dt > 0 else { continue }
            weightedSum += sorted[i].depthM * dt
            totalDt += dt
        }
        // Fallback to arithmetic mean if all timestamps are equal
        let avgD = totalDt > 0
            ? weightedSum / totalDt
            : sorted.map(\.depthM).reduce(0, +) / Float(sorted.count)

        return BasicStats(
            startTSec: startT,
            endTSec: endT,
            maxDepthM: maxD,
            avgDepthM: avgD,
            bottomTimeSec: endT - startT,
            minTempC: minT,
            maxTempC: maxT,
            avgTempC: avgT,
            maxCeilingM: maxCeiling
        )
    }

    /// Links an existing dive to a new BLE fingerprint (skips if already linked).
    private func linkFingerprint(
        _ fingerprint: Data, deviceId: String, toDiveId diveId: String
    ) throws {
        try database.dbQueue.write { db in
            try Self.insertSourceFingerprint(
                fingerprint, deviceId: deviceId, diveId: diveId, db: db
            )
        }
    }

    /// Inserts a `DiveSourceFingerprint` record if one with the same fingerprint
    /// doesn't already exist.
    private static func insertSourceFingerprint(
        _ fingerprint: Data, deviceId: String, diveId: String, db: Database
    ) throws {
        let exists = try DiveSourceFingerprint
            .filter(Column("fingerprint") == fingerprint)
            .fetchCount(db) > 0
        guard !exists else { return }
        try DiveSourceFingerprint(
            diveId: diveId,
            deviceId: deviceId,
            fingerprint: fingerprint,
            sourceType: "ble"
        ).insert(db)
    }
}
