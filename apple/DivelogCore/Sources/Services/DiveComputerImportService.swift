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

    /// Checks whether a dive with the given fingerprint already exists.
    /// - Parameter fingerprint: The fingerprint blob from the dive computer.
    /// - Returns: `true` if a dive with this fingerprint is already stored.
    public func isDuplicate(fingerprint: Data) throws -> Bool {
        try database.dbQueue.read { db in
            try Dive
                .filter(Column("fingerprint") == fingerprint)
                .fetchCount(db) > 0
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
    /// If a dive with the same fingerprint already exists, the save is skipped
    /// (idempotent). Returns `true` if the dive was saved, `false` if it was a duplicate.
    /// - Parameters:
    ///   - parsed: The parsed dive data from the dive computer.
    ///   - deviceId: The device ID to associate with the dive.
    /// - Returns: `true` if the dive was newly saved, `false` if skipped as duplicate.
    @discardableResult
    public func saveImportedDive(_ parsed: ParsedDive, deviceId: String) throws -> Bool {
        // Check fingerprint-based dedup before the write transaction
        if let fp = parsed.fingerprint {
            if try isDuplicate(fingerprint: fp) {
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
            // Double-check inside the transaction to avoid TOCTOU races
            if let fp = dive.fingerprint {
                let exists = try Dive
                    .filter(Column("fingerprint") == fp)
                    .fetchCount(db) > 0
                if exists { return }
            }

            try dive.insert(db)
            let typeTag = PredefinedDiveTag.diveTypeTag(isCcr: dive.isCcr)
            try DiveTag(diveId: dive.id, tag: typeTag.rawValue).insert(db)
            for activityTag in PredefinedDiveTag.autoActivityTags(decoRequired: dive.decoRequired) {
                try DiveTag(diveId: dive.id, tag: activityTag.rawValue).insert(db)
            }
            for sample in samples {
                try sample.insert(db)
            }
            for mix in uniqueMixes {
                try mix.insert(db)
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
}
