import Foundation
import GRDB

/// Service for exporting and importing dive data.
public final class ExportService: Sendable {
    private let database: DivelogDatabase

    public init(database: DivelogDatabase) {
        self.database = database
    }

    // MARK: - Export

    /// Export all data to JSON.
    public func exportAll(description: String? = nil) throws -> Data {
        let export = try database.dbQueue.read { db -> ExportData in
            ExportData(
                version: 1,
                exportedAt: Date(),
                description: description,
                devices: try Device.fetchAll(db),
                sites: try Site.fetchAll(db),
                buddies: try Buddy.fetchAll(db),
                equipment: try Equipment.fetchAll(db),
                formulas: try Formula.fetchAll(db),
                dives: try fetchDivesWithRelations(db)
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        return try encoder.encode(export)
    }

    private func fetchDivesWithRelations(_ db: Database) throws -> [ExportDive] {
        let dives = try Dive.fetchAll(db)

        return try dives.map { dive in
            let tags = try DiveTag
                .filter(Column("dive_id") == dive.id)
                .fetchAll(db)
                .map { $0.tag }

            let buddyIds = try DiveBuddy
                .filter(Column("dive_id") == dive.id)
                .fetchAll(db)
                .map { $0.buddyId }

            let equipmentIds = try DiveEquipment
                .filter(Column("dive_id") == dive.id)
                .fetchAll(db)
                .map { $0.equipmentId }

            let samples = try DiveSample
                .filter(Column("dive_id") == dive.id)
                .order(Column("t_sec"))
                .fetchAll(db)

            let segments = try fetchSegmentsWithTags(db, diveId: dive.id)

            return ExportDive(
                dive: dive,
                tags: tags,
                buddyIds: buddyIds,
                equipmentIds: equipmentIds,
                samples: samples,
                segments: segments
            )
        }
    }

    private func fetchSegmentsWithTags(_ db: Database, diveId: String) throws -> [ExportSegment] {
        let segments = try Segment
            .filter(Column("dive_id") == diveId)
            .order(Column("start_t_sec"))
            .fetchAll(db)

        return try segments.map { segment in
            let tags = try SegmentTag
                .filter(Column("segment_id") == segment.id)
                .fetchAll(db)
                .map { $0.tag }

            return ExportSegment(segment: segment, tags: tags)
        }
    }

    // MARK: - Import

    /// Import data from JSON.
    public func importJSON(_ data: Data) throws -> ImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let importData = try decoder.decode(ExportData.self, from: data)

        var result = ImportResult()

        try database.dbQueue.write { db in
            // Import devices
            for device in importData.devices {
                try device.save(db)
                result.devicesImported += 1
            }

            // Import sites
            for site in importData.sites {
                try site.save(db)
                result.sitesImported += 1
            }

            // Import buddies
            for buddy in importData.buddies {
                try buddy.save(db)
                result.buddiesImported += 1
            }

            // Import equipment
            for equipment in importData.equipment {
                try equipment.save(db)
                result.equipmentImported += 1
            }

            // Import formulas
            for formula in importData.formulas {
                try formula.save(db)
                result.formulasImported += 1
            }

            // Import dives with relations
            for exportDive in importData.dives {
                try exportDive.dive.save(db)

                // Tags
                for tag in exportDive.tags {
                    try DiveTag(diveId: exportDive.dive.id, tag: tag).insert(db)
                }

                // Buddies
                for buddyId in exportDive.buddyIds {
                    try DiveBuddy(diveId: exportDive.dive.id, buddyId: buddyId).insert(db)
                }

                // Equipment
                for equipmentId in exportDive.equipmentIds {
                    try DiveEquipment(diveId: exportDive.dive.id, equipmentId: equipmentId).insert(db)
                }

                // Samples
                for sample in exportDive.samples {
                    try sample.save(db)
                }

                // Segments
                for exportSegment in exportDive.segments {
                    try exportSegment.segment.save(db)
                    for tag in exportSegment.tags {
                        try SegmentTag(segmentId: exportSegment.segment.id, tag: tag).insert(db)
                    }
                }

                result.divesImported += 1
            }
        }

        return result
    }
}

// MARK: - Export Data Types

/// Root export structure.
public struct ExportData: Codable, Sendable {
    public let version: Int
    public let exportedAt: Date
    public let description: String?
    public let devices: [Device]
    public let sites: [Site]
    public let buddies: [Buddy]
    public let equipment: [Equipment]
    public let formulas: [Formula]
    public let dives: [ExportDive]
}

/// Dive with all relations for export.
public struct ExportDive: Codable, Sendable {
    public let dive: Dive
    public let tags: [String]
    public let buddyIds: [String]
    public let equipmentIds: [String]
    public let samples: [DiveSample]
    public let segments: [ExportSegment]
}

/// Segment with tags for export.
public struct ExportSegment: Codable, Sendable {
    public let segment: Segment
    public let tags: [String]
}

/// Result of an import operation.
public struct ImportResult: Sendable {
    public var devicesImported: Int = 0
    public var sitesImported: Int = 0
    public var buddiesImported: Int = 0
    public var equipmentImported: Int = 0
    public var formulasImported: Int = 0
    public var divesImported: Int = 0

    public var totalImported: Int {
        devicesImported + sitesImported + buddiesImported +
        equipmentImported + formulasImported + divesImported
    }
}
