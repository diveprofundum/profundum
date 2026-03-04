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
/// Marked `@unchecked Sendable` because all mutable state is accessed from
/// a single writer (the download task's `onDive` callback and the retry loop,
/// which execute sequentially within `DiveDownloader.download()`). No lock
/// is needed because there is no concurrent mutation.
public final class ImportProgressTracker: @unchecked Sendable {
    public let consecutiveSkipThreshold: Int
    nonisolated(unsafe) public private(set) var saved = 0
    nonisolated(unsafe) public private(set) var merged = 0
    nonisolated(unsafe) public private(set) var skipped = 0
    nonisolated(unsafe) public private(set) var consecutiveSkips = 0

    public init(consecutiveSkipThreshold: Int = 10) {
        self.consecutiveSkipThreshold = consecutiveSkipThreshold
    }

    public func record(_ outcome: ImportOutcome) {
        switch outcome {
        case .saved:  saved += 1; consecutiveSkips = 0
        case .merged: merged += 1; consecutiveSkips = 0
        case .skipped: skipped += 1; consecutiveSkips += 1
        }
    }

    public var shouldAutoStop: Bool { consecutiveSkips >= consecutiveSkipThreshold }

    /// Resets the consecutive skip counter without losing accumulated totals.
    ///
    /// Called before a retry attempt so that re-enumerated (already-saved) dives
    /// don't trigger auto-stop prematurely.
    public func resetConsecutiveSkips() {
        consecutiveSkips = 0
    }
}

/// Key for deduplicating gas mixes by composition and usage.
struct GasMixKey: Hashable {
    let o2: Int   // o2Fraction * 1000 as integer for reliable hashing
    let he: Int   // heFraction * 1000 as integer for reliable hashing
    let usage: String?
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

    /// Finds an existing dive by start time from a different device (cross-source dedup).
    /// - Parameters:
    ///   - startTimeUnix: The start time to search for.
    ///   - deviceId: The device ID of the incoming dive (excluded from results).
    /// - Returns: The existing dive's ID if found within ±300s from a different device, or `nil`.
    public func findExistingDiveByTime(startTimeUnix: Int64, deviceId: String) throws -> String? {
        try database.dbQueue.read { db in
            try Self.findExistingDiveByTime(startTimeUnix: startTimeUnix, deviceId: deviceId, db: db)
        }
    }

    /// Returns the most recent fingerprint for a given device, ordered by dive start time.
    ///
    /// Used for incremental sync: pass this fingerprint to libdivecomputer so it
    /// stops downloading once it reaches a dive we already have.
    /// - Parameter deviceId: The device to look up.
    /// - Returns: The fingerprint of the newest dive from this device, or `nil`.
    public func lastFingerprint(deviceId: String) throws -> Data? {
        try database.dbQueue.read { db in
            try Dive
                .filter(Column("device_id") == deviceId)
                .filter(Column("fingerprint") != nil)
                .order(Column("start_time_unix").desc)
                .fetchOne(db)?
                .fingerprint
        }
    }

    /// Saves an imported dive and its samples transactionally.
    ///
    /// Dedup strategy (in order):
    /// 1. **Fingerprint dedup** — checks both legacy `dives.fingerprint` and
    ///    `dive_source_fingerprints`. If matched, links the BLE fingerprint to
    ///    the existing dive and returns `.skipped`.
    /// 2. **Time-based cross-source match** — if a dive with the same
    ///    `start_time_unix` (±300s) exists from a different device:
    ///    - If the existing dive already has samples from this device → `.skipped`
    ///    - Otherwise → merge samples + gas mixes into existing dive → `.merged`
    /// 3. **New dive** — inserts dive, tags, samples, gas mixes, and a
    ///    `DiveSourceFingerprint` record → `.saved`.
    ///
    /// - Parameters:
    ///   - parsed: The parsed dive data from the dive computer.
    ///   - deviceId: The device ID to associate with the dive.
    /// - Returns: The import outcome (.saved, .merged, or .skipped).
    @discardableResult
    public func saveImportedDive(_ parsed: ParsedDive, deviceId: String) throws -> ImportOutcome {
        // Fast path: fingerprint-exact-match → skip without write lock
        if let fp = parsed.fingerprint,
           let existingDiveId = try findExistingDiveByFingerprint(fingerprint: fp) {
            try linkFingerprint(fp, deviceId: deviceId, toDiveId: existingDiveId)
            return .skipped
        }

        // Prepare domain objects outside the write lock (pure mapping)
        let (dive, samples, gasMixes) = DiveDataMapper.toDive(parsed, deviceId: deviceId)

        // Deduplicate gas mixes by (o2, he, usage)
        var seenMixes = Set<GasMixKey>()
        var uniqueMixes: [GasMix] = []
        for mix in gasMixes {
            let key = GasMixKey(
                o2: Int(mix.o2Fraction * 1000),
                he: Int(mix.heFraction * 1000),
                usage: mix.usage
            )
            if seenMixes.insert(key).inserted {
                uniqueMixes.append(mix)
            }
        }
        // Re-index sequentially
        for i in uniqueMixes.indices {
            uniqueMixes[i].mixIndex = i
        }

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
                    try Self.insertSourceFingerprint(
                        fp, deviceId: deviceId, diveId: existingDiveId, db: db
                    )
                    return .skipped
                }
            }

            // Time-based cross-source match → merge or skip
            if let fp = parsed.fingerprint,
               let existingDiveId = try Self.findExistingDiveByTime(
                   startTimeUnix: parsed.startTimeUnix, deviceId: deviceId, db: db
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
            for sample in samples {
                try sample.insert(db)
            }
            for mix in uniqueMixes {
                try mix.insert(db)
            }

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
        // Build index remap from incoming gas mix indices → persisted indices.
        // This must happen BEFORE inserting samples so gasmixIndex values are correct.
        let existingMixes = try GasMix
            .filter(Column("dive_id") == existingDiveId)
            .fetchAll(db)
        // Use uniquingKeysWith to handle potential duplicate compositions in existing data
        // (no DB uniqueness constraint). Keep the lowest mixIndex for stability.
        var mixByKey: [GasMixKey: Int] = Dictionary(
            existingMixes.map {
                (GasMixKey(o2: Int($0.o2Fraction * 1000), he: Int($0.heFraction * 1000), usage: $0.usage),
                 $0.mixIndex)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var nextMixIndex = (existingMixes.map(\.mixIndex).max() ?? -1) + 1

        var indexRemap: [Int: Int] = [:]
        for m in parsed.gasMixes {
            let key = GasMixKey(o2: Int(m.o2Fraction * 1000), he: Int(m.heFraction * 1000), usage: m.usage)
            if let existingIdx = mixByKey[key] {
                indexRemap[m.index] = existingIdx
            } else {
                indexRemap[m.index] = nextMixIndex
                mixByKey[key] = nextMixIndex
                try GasMix(
                    diveId: existingDiveId,
                    mixIndex: nextMixIndex,
                    o2Fraction: m.o2Fraction,
                    heFraction: m.heFraction,
                    usage: m.usage
                ).insert(db)
                nextMixIndex += 1
            }
        }

        // Insert samples with remapped gas mix indices
        for s in parsed.samples {
            try DiveSample(
                diveId: existingDiveId,
                deviceId: deviceId,
                tSec: s.tSec,
                depthM: s.depthM,
                tempC: s.tempC,
                setpointPpo2: s.setpointPpo2,
                ceilingM: s.ceilingM,
                gf99: s.gf99,
                ppo2_1: s.ppo2_1,
                ppo2_2: s.ppo2_2,
                ppo2_3: s.ppo2_3,
                cns: s.cns,
                tankPressure1Bar: s.tankPressure1Bar,
                tankPressure2Bar: s.tankPressure2Bar,
                ttsSec: s.ttsSec,
                ndlSec: s.ndlSec,
                decoStopDepthM: s.decoStopDepthM,
                rbtSec: s.rbtSec,
                gasmixIndex: s.gasmixIndex.flatMap { indexRemap[$0] },
                atPlusFiveTtsMin: s.atPlusFiveTtsMin
            ).insert(db)
        }

        // Link fingerprint
        if let fp = parsed.fingerprint {
            try Self.insertSourceFingerprint(fp, deviceId: deviceId, diveId: existingDiveId, db: db)
        }
    }

    // MARK: - Private Helpers

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

    /// Finds an existing dive by start time from a different device.
    /// Uses ±300s tolerance to handle clock drift between import paths.
    /// 5 minutes is well under the shortest realistic surface interval.
    private static func findExistingDiveByTime(
        startTimeUnix: Int64, deviceId: String, db: Database
    ) throws -> String? {
        let row = try Row.fetchOne(db, sql: """
            SELECT id FROM dives
            WHERE ABS(start_time_unix - ?) <= 300
              AND device_id != ?
            LIMIT 1
            """, arguments: [startTimeUnix, deviceId])
        return row?["id"] as String?
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
