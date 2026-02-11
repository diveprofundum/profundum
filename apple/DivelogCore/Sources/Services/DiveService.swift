import Foundation
import GRDB

/// Main service for dive data operations.
public final class DiveService: Sendable {
    private let database: DivelogDatabase

    public init(database: DivelogDatabase) {
        self.database = database
    }

    // MARK: - Device Operations

    public func saveDevice(_ device: Device) throws {
        try database.dbQueue.write { db in
            try device.save(db)
        }
    }

    public func getDevice(id: String) throws -> Device? {
        try database.dbQueue.read { db in
            try Device.fetchOne(db, key: id)
        }
    }

    /// List devices, optionally including archived ones.
    /// - Parameter includeArchived: If true, returns all devices. If false (default), returns only active devices.
    public func listDevices(includeArchived: Bool = false) throws -> [Device] {
        try database.dbQueue.read { db in
            if includeArchived {
                try Device.fetchAll(db)
            } else {
                try Device.filter(Column("is_active") == true).fetchAll(db)
            }
        }
    }

    /// Archive a device (soft-delete). The device remains in the database for dive history provenance.
    public func archiveDevice(id: String) throws -> Bool {
        try database.dbQueue.write { db in
            if var device = try Device.fetchOne(db, key: id) {
                device.isActive = false
                try device.update(db)
                return true
            }
            return false
        }
    }

    /// Restore an archived device to active status.
    public func restoreDevice(id: String) throws -> Bool {
        try database.dbQueue.write { db in
            if var device = try Device.fetchOne(db, key: id) {
                device.isActive = true
                try device.update(db)
                return true
            }
            return false
        }
    }

    /// Permanently delete a device. Use archiveDevice for soft-delete.
    /// Note: This will fail if dives reference this device (foreign key constraint).
    public func deleteDevice(id: String) throws -> Bool {
        try database.dbQueue.write { db in
            try Device.deleteOne(db, key: id)
        }
    }

    // MARK: - Site Operations

    public func saveSite(_ site: Site, tags: [String] = []) throws {
        try database.dbQueue.write { db in
            try site.save(db)
            // Delete existing tags and insert new ones
            try SiteTag.filter(Column("site_id") == site.id).deleteAll(db)
            for tag in tags {
                try SiteTag(siteId: site.id, tag: tag).insert(db)
            }
        }
    }

    public func getSite(id: String) throws -> Site? {
        try database.dbQueue.read { db in
            try Site.fetchOne(db, key: id)
        }
    }

    public func listSites() throws -> [Site] {
        try database.dbQueue.read { db in
            try Site.fetchAll(db)
        }
    }

    public func deleteSite(id: String) throws -> Bool {
        try database.dbQueue.write { db in
            try Site.deleteOne(db, key: id)
        }
    }

    // MARK: - Teammate Operations

    public func saveTeammate(_ teammate: Teammate) throws {
        try database.dbQueue.write { db in
            try teammate.save(db)
        }
    }

    public func getTeammate(id: String) throws -> Teammate? {
        try database.dbQueue.read { db in
            try Teammate.fetchOne(db, key: id)
        }
    }

    public func listTeammates() throws -> [Teammate] {
        try database.dbQueue.read { db in
            try Teammate.fetchAll(db)
        }
    }

    public func deleteTeammate(id: String) throws -> Bool {
        try database.dbQueue.write { db in
            try Teammate.deleteOne(db, key: id)
        }
    }

    // MARK: - Equipment Operations

    public func saveEquipment(_ equipment: Equipment) throws {
        try database.dbQueue.write { db in
            try equipment.save(db)
        }
    }

    public func getEquipment(id: String) throws -> Equipment? {
        try database.dbQueue.read { db in
            try Equipment.fetchOne(db, key: id)
        }
    }

    public func listEquipment() throws -> [Equipment] {
        try database.dbQueue.read { db in
            try Equipment.fetchAll(db)
        }
    }

    public func deleteEquipment(id: String) throws -> Bool {
        try database.dbQueue.write { db in
            try Equipment.deleteOne(db, key: id)
        }
    }

    // MARK: - Dive Operations

    public func saveDive(
        _ dive: Dive, tags: [String] = [],
        teammateIds: [String] = [], equipmentIds: [String] = []
    ) throws {
        try database.dbQueue.write { db in
            try dive.save(db)

            // Update tags
            try DiveTag.filter(Column("dive_id") == dive.id).deleteAll(db)
            for tag in tags {
                try DiveTag(diveId: dive.id, tag: tag).insert(db)
            }

            // Update teammates
            try DiveTeammate.filter(Column("dive_id") == dive.id).deleteAll(db)
            for teammateId in teammateIds {
                try DiveTeammate(diveId: dive.id, teammateId: teammateId).insert(db)
            }

            // Update equipment
            try DiveEquipment.filter(Column("dive_id") == dive.id).deleteAll(db)
            for equipmentId in equipmentIds {
                try DiveEquipment(diveId: dive.id, equipmentId: equipmentId).insert(db)
            }
        }
    }

    public func getDive(id: String) throws -> Dive? {
        try database.dbQueue.read { db in
            try Dive.fetchOne(db, key: id)
        }
    }

    public func listDives(query: DiveQuery = DiveQuery()) throws -> [Dive] {
        try database.dbQueue.read { db in
            try query.request().fetchAll(db)
        }
    }

    /// List dives with their site names in a single query (avoids N+1).
    public func listDivesWithSites(query: DiveQuery = DiveQuery()) throws -> [DiveWithSite] {
        try database.dbQueue.read { db in
            try query.requestWithSites().fetchAll(db)
        }
    }

    public func deleteDive(id: String) throws -> Bool {
        try database.dbQueue.write { db in
            try Dive.deleteOne(db, key: id)
        }
    }

    /// Get all teammate IDs for a specific dive.
    public func getTeammateIds(diveId: String) throws -> [String] {
        try database.dbQueue.read { db in
            try Row
                .fetchAll(db, sql: "SELECT buddy_id FROM dive_buddies WHERE dive_id = ?", arguments: [diveId])
                .map { $0["buddy_id"] as String }
        }
    }

    /// Get all equipment IDs for a specific dive.
    public func getEquipmentIds(diveId: String) throws -> [String] {
        try database.dbQueue.read { db in
            try Row
                .fetchAll(db, sql: "SELECT equipment_id FROM dive_equipment WHERE dive_id = ?", arguments: [diveId])
                .map { $0["equipment_id"] as String }
        }
    }

    /// Get all tags for a specific dive.
    public func getTags(diveId: String) throws -> [String] {
        try database.dbQueue.read { db in
            try DiveTag
                .filter(Column("dive_id") == diveId)
                .fetchAll(db)
                .map(\.tag)
        }
    }

    // MARK: - Batch Detail Loading

    /// All relations for a single dive, loaded in one read transaction.
    public struct DiveDetail: Sendable {
        public let samples: [DiveSample]
        public let tags: [String]
        public let gasMixes: [GasMix]
        public let teammateIds: [String]
        public let equipmentIds: [String]
        public let sourceFingerprints: [DiveSourceFingerprint]
        public let sourceDeviceNames: [String]
    }

    /// Load all dive relations in a single read transaction (eliminates N+1 queries).
    public func getDiveDetail(diveId: String) throws -> DiveDetail {
        try database.dbQueue.read { db in
            let samples = try DiveSample
                .filter(Column("dive_id") == diveId)
                .order(Column("t_sec"))
                .fetchAll(db)

            let tags = try DiveTag
                .filter(Column("dive_id") == diveId)
                .fetchAll(db)
                .map(\.tag)

            let gasMixes = try GasMix
                .filter(Column("dive_id") == diveId)
                .order(Column("mix_index"))
                .fetchAll(db)

            let teammateIds = try Row
                .fetchAll(db, sql: "SELECT buddy_id FROM dive_buddies WHERE dive_id = ?", arguments: [diveId])
                .map { $0["buddy_id"] as String }

            let equipmentIds = try Row
                .fetchAll(db, sql: "SELECT equipment_id FROM dive_equipment WHERE dive_id = ?", arguments: [diveId])
                .map { $0["equipment_id"] as String }

            let sourceFingerprints = try DiveSourceFingerprint
                .filter(Column("dive_id") == diveId)
                .fetchAll(db)

            // Batch-fetch device names for all source fingerprint device IDs
            let deviceIds = Array(Set(sourceFingerprints.map(\.deviceId)))
            var sourceDeviceNames: [String] = []
            if !deviceIds.isEmpty {
                let devices = try Device
                    .filter(deviceIds.contains(Column("id")))
                    .fetchAll(db)
                sourceDeviceNames = devices.map { device in
                    device.serialNumber != "unknown"
                        ? "\(device.model) (\(device.serialNumber))"
                        : device.model
                }
            }

            return DiveDetail(
                samples: samples,
                tags: tags,
                gasMixes: gasMixes,
                teammateIds: teammateIds,
                equipmentIds: equipmentIds,
                sourceFingerprints: sourceFingerprints,
                sourceDeviceNames: sourceDeviceNames
            )
        }
    }

    // MARK: - Surface Interval

    /// Calculate the surface interval before a dive (time since previous dive ended).
    /// Returns nil if this is the first dive or no previous dive exists.
    public func surfaceInterval(beforeDive dive: Dive) throws -> Int64? {
        try database.dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT end_time_unix FROM dives
                WHERE end_time_unix <= ? AND id != ?
                ORDER BY end_time_unix DESC LIMIT 1
            """, arguments: [dive.startTimeUnix, dive.id])
            guard let prevEnd = row?["end_time_unix"] as Int64? else { return nil }
            return dive.startTimeUnix - prevEnd
        }
    }

    // MARK: - Sample Operations

    public func saveSamples(_ samples: [DiveSample]) throws {
        try database.dbQueue.write { db in
            for sample in samples {
                try sample.save(db)
            }
        }
    }

    public func getSamples(diveId: String) throws -> [DiveSample] {
        try database.dbQueue.read { db in
            try DiveSample
                .filter(Column("dive_id") == diveId)
                .order(Column("t_sec"))
                .fetchAll(db)
        }
    }

    public func deleteSamples(diveId: String) throws -> Int {
        try database.dbQueue.write { db in
            try DiveSample.filter(Column("dive_id") == diveId).deleteAll(db)
        }
    }

    // MARK: - Gas Mix Operations

    public func saveGasMixes(_ mixes: [GasMix]) throws {
        try database.dbQueue.write { db in
            for mix in mixes {
                try mix.save(db)
            }
        }
    }

    public func getGasMixes(diveId: String) throws -> [GasMix] {
        let allMixes = try database.dbQueue.read { db in
            try GasMix
                .filter(Column("dive_id") == diveId)
                .order(Column("mix_index"))
                .fetchAll(db)
        }
        // Read-time dedup safety net for pre-fix data
        struct MixKey: Hashable {
            let o2: Int, he: Int, usage: String?
        }
        var seen = Set<MixKey>()
        return allMixes.filter { mix in
            let key = MixKey(o2: Int(mix.o2Fraction * 1000), he: Int(mix.heFraction * 1000), usage: mix.usage)
            return seen.insert(key).inserted
        }
    }

    public func deleteGasMixes(diveId: String) throws -> Int {
        try database.dbQueue.write { db in
            try GasMix.filter(Column("dive_id") == diveId).deleteAll(db)
        }
    }

    // MARK: - Source Fingerprint Operations

    public func saveSourceFingerprints(_ fps: [DiveSourceFingerprint]) throws {
        try database.dbQueue.write { db in
            for fp in fps {
                try fp.save(db)
            }
        }
    }

    public func getSourceFingerprints(diveId: String) throws -> [DiveSourceFingerprint] {
        try database.dbQueue.read { db in
            try DiveSourceFingerprint
                .filter(Column("dive_id") == diveId)
                .fetchAll(db)
        }
    }

    public func findDiveByFingerprint(_ fingerprint: Data) throws -> DiveSourceFingerprint? {
        try database.dbQueue.read { db in
            try DiveSourceFingerprint
                .filter(Column("fingerprint") == fingerprint)
                .fetchOne(db)
        }
    }

    // MARK: - Segment Operations

    public func saveSegment(_ segment: Segment, tags: [String] = []) throws {
        try database.dbQueue.write { db in
            try segment.save(db)
            try SegmentTag.filter(Column("segment_id") == segment.id).deleteAll(db)
            for tag in tags {
                try SegmentTag(segmentId: segment.id, tag: tag).insert(db)
            }
        }
    }

    public func getSegment(id: String) throws -> Segment? {
        try database.dbQueue.read { db in
            try Segment.fetchOne(db, key: id)
        }
    }

    public func listSegments(diveId: String) throws -> [Segment] {
        try database.dbQueue.read { db in
            try Segment
                .filter(Column("dive_id") == diveId)
                .order(Column("start_t_sec"))
                .fetchAll(db)
        }
    }

    public func deleteSegment(id: String) throws -> Bool {
        try database.dbQueue.write { db in
            try Segment.deleteOne(db, key: id)
        }
    }

    // MARK: - Formula Operations

    public func saveFormula(_ formula: Formula) throws {
        try database.dbQueue.write { db in
            try formula.save(db)
        }
    }

    public func getFormula(id: String) throws -> Formula? {
        try database.dbQueue.read { db in
            try Formula.fetchOne(db, key: id)
        }
    }

    public func listFormulas() throws -> [Formula] {
        try database.dbQueue.read { db in
            try Formula.fetchAll(db)
        }
    }

    public func deleteFormula(id: String) throws -> Bool {
        try database.dbQueue.write { db in
            try Formula.deleteOne(db, key: id)
        }
    }

    // MARK: - Settings Operations

    public func saveSettings(_ settings: Settings) throws {
        try database.dbQueue.write { db in
            try settings.save(db)
        }
    }

    public func getSettings(id: String = "default") throws -> Settings? {
        try database.dbQueue.read { db in
            try Settings.fetchOne(db, key: id)
        }
    }

    // MARK: - Calculated Field Operations

    public func saveCalculatedField(_ field: CalculatedField) throws {
        try database.dbQueue.write { db in
            try field.save(db)
        }
    }

    public func listCalculatedFields(diveId: String) throws -> [CalculatedField] {
        try database.dbQueue.read { db in
            try CalculatedField.filter(Column("dive_id") == diveId).fetchAll(db)
        }
    }

    public func deleteCalculatedField(formulaId: String, diveId: String) throws -> Bool {
        try database.dbQueue.write { db in
            try CalculatedField
                .filter(Column("formula_id") == formulaId && Column("dive_id") == diveId)
                .deleteAll(db) > 0
        }
    }
}
