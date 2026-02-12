import Foundation
import GRDB

/// Key for deduplicating gas mixes by composition and usage.
private struct GasMixKey: Hashable {
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
    ///    the existing dive and returns `false`.
    /// 2. **Time-based cross-source dedup** — if a dive with the same
    ///    `start_time_unix` (±60s) exists from a different device, links the
    ///    BLE fingerprint to the existing dive and returns `false`.
    /// 3. **New dive** — inserts dive, tags, samples, gas mixes, and a
    ///    `DiveSourceFingerprint` record.
    ///
    /// - Parameters:
    ///   - parsed: The parsed dive data from the dive computer.
    ///   - deviceId: The device ID to associate with the dive.
    /// - Returns: `true` if the dive was newly saved, `false` if skipped as duplicate.
    @discardableResult
    public func saveImportedDive(_ parsed: ParsedDive, deviceId: String) throws -> Bool {
        // Pre-check: fingerprint-based dedup (legacy + source_fingerprints)
        if let fp = parsed.fingerprint {
            if let existingDiveId = try findExistingDiveByFingerprint(fingerprint: fp) {
                try linkFingerprint(fp, deviceId: deviceId, toDiveId: existingDiveId)
                return false
            }

            // Pre-check: time-based cross-source dedup
            if let existingDiveId = try findExistingDiveByTime(
                startTimeUnix: parsed.startTimeUnix, deviceId: deviceId
            ) {
                try linkFingerprint(fp, deviceId: deviceId, toDiveId: existingDiveId)
                return false
            }
        }

        let (dive, samples, gasMixes) = DiveDataMapper.toDive(parsed, deviceId: deviceId)

        // Deduplicate gas mixes by (o2, he, usage)
        var seenMixes = Set<GasMixKey>()
        var uniqueMixes: [GasMix] = []
        for mix in gasMixes {
            let key = GasMixKey(o2: Int(mix.o2Fraction * 1000), he: Int(mix.heFraction * 1000), usage: mix.usage)
            if seenMixes.insert(key).inserted {
                uniqueMixes.append(mix)
            }
        }
        // Re-index sequentially
        for i in uniqueMixes.indices {
            uniqueMixes[i].mixIndex = i
        }

        try database.dbQueue.write { db in
            // TOCTOU double-check inside the write transaction
            if let fp = dive.fingerprint {
                if let existingDiveId = try Self.findExistingDiveByFingerprint(
                    fingerprint: fp, db: db
                ) {
                    try Self.insertSourceFingerprint(
                        fp, deviceId: deviceId, diveId: existingDiveId, db: db
                    )
                    return
                }
                if let existingDiveId = try Self.findExistingDiveByTime(
                    startTimeUnix: dive.startTimeUnix, deviceId: deviceId, db: db
                ) {
                    try Self.insertSourceFingerprint(
                        fp, deviceId: deviceId, diveId: existingDiveId, db: db
                    )
                    return
                }
            }

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
        }

        return true
    }

    /// Saves multiple imported dives, skipping duplicates.
    /// - Parameters:
    ///   - parsedDives: The parsed dive data from the dive computer.
    ///   - deviceId: The device ID to associate with the dives.
    /// - Returns: The number of dives that were newly saved (not duplicates).
    public func saveImportedDives(_ parsedDives: [ParsedDive], deviceId: String) throws -> Int {
        var saved = 0
        for parsed in parsedDives where try saveImportedDive(parsed, deviceId: deviceId) {
            saved += 1
        }
        return saved
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
