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
                buddies: try Teammate.fetchAll(db),
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
        guard !dives.isEmpty else { return [] }

        // Bulk-fetch all relations (7 queries total, regardless of dive count)
        let allTags = try DiveTag.fetchAll(db)
        let allTeammates = try DiveTeammate.fetchAll(db)
        let allEquipment = try DiveEquipment.fetchAll(db)
        let allSamples = try DiveSample.order(Column("t_sec")).fetchAll(db)
        let allSegments = try Segment.order(Column("start_t_sec")).fetchAll(db)
        let allSegmentTags = try SegmentTag.fetchAll(db)

        // Group by dive_id in memory
        let tagsByDive = Dictionary(grouping: allTags, by: \.diveId)
        let teammatesByDive = Dictionary(grouping: allTeammates, by: \.diveId)
        let equipmentByDive = Dictionary(grouping: allEquipment, by: \.diveId)
        let samplesByDive = Dictionary(grouping: allSamples, by: \.diveId)
        let segmentsByDive = Dictionary(grouping: allSegments, by: \.diveId)
        let segTagsBySegment = Dictionary(grouping: allSegmentTags, by: \.segmentId)

        return dives.map { dive in
            let segments = (segmentsByDive[dive.id] ?? []).map { segment in
                ExportSegment(
                    segment: segment,
                    tags: (segTagsBySegment[segment.id] ?? []).map(\.tag)
                )
            }

            return ExportDive(
                dive: dive,
                tags: (tagsByDive[dive.id] ?? []).map(\.tag),
                buddyIds: (teammatesByDive[dive.id] ?? []).map(\.teammateId),
                equipmentIds: (equipmentByDive[dive.id] ?? []).map(\.equipmentId),
                samples: samplesByDive[dive.id] ?? [],
                segments: segments
            )
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

                // Teammates
                for teammateId in exportDive.buddyIds {
                    try DiveTeammate(diveId: exportDive.dive.id, teammateId: teammateId).insert(db)
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
    public let buddies: [Teammate]
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
