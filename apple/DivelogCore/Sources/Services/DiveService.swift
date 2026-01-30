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

    public func listDevices() throws -> [Device] {
        try database.dbQueue.read { db in
            try Device.fetchAll(db)
        }
    }

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

    // MARK: - Buddy Operations

    public func saveBuddy(_ buddy: Buddy) throws {
        try database.dbQueue.write { db in
            try buddy.save(db)
        }
    }

    public func getBuddy(id: String) throws -> Buddy? {
        try database.dbQueue.read { db in
            try Buddy.fetchOne(db, key: id)
        }
    }

    public func listBuddies() throws -> [Buddy] {
        try database.dbQueue.read { db in
            try Buddy.fetchAll(db)
        }
    }

    public func deleteBuddy(id: String) throws -> Bool {
        try database.dbQueue.write { db in
            try Buddy.deleteOne(db, key: id)
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

    public func saveDive(_ dive: Dive, tags: [String] = [], buddyIds: [String] = [], equipmentIds: [String] = []) throws {
        try database.dbQueue.write { db in
            try dive.save(db)

            // Update tags
            try DiveTag.filter(Column("dive_id") == dive.id).deleteAll(db)
            for tag in tags {
                try DiveTag(diveId: dive.id, tag: tag).insert(db)
            }

            // Update buddies
            try DiveBuddy.filter(Column("dive_id") == dive.id).deleteAll(db)
            for buddyId in buddyIds {
                try DiveBuddy(diveId: dive.id, buddyId: buddyId).insert(db)
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

    public func deleteDive(id: String) throws -> Bool {
        try database.dbQueue.write { db in
            try Dive.deleteOne(db, key: id)
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
