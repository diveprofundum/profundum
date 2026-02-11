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

    /// Export selected dives (with all related data) to JSON.
    /// When `ids` is empty, exports all dives.
    public func exportDives(ids: [String], description: String? = nil) throws -> Data {
        let export = try database.dbQueue.read { db -> ExportData in
            let dives: [Dive]
            if ids.isEmpty {
                dives = try Dive.fetchAll(db)
            } else {
                dives = try Dive.filter(ids.contains(Column("id"))).fetchAll(db)
            }

            // Collect referenced device/site IDs from the selected dives
            let deviceIds = Set(dives.map(\.deviceId))
            let siteIds = Set(dives.compactMap(\.siteId))

            return ExportData(
                version: 1,
                exportedAt: Date(),
                description: description,
                devices: try Device.filter(deviceIds.contains(Column("id"))).fetchAll(db),
                sites: try Site.filter(siteIds.contains(Column("id"))).fetchAll(db),
                buddies: [],
                equipment: [],
                formulas: [],
                dives: try fetchRelations(for: dives, in: db)
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        return try encoder.encode(export)
    }

    /// Export dives as a CSV summary table.
    /// When `ids` is empty, exports all dives.
    public func exportDivesAsCSV(ids: [String]) throws -> Data {
        let rows = try database.dbQueue.read { db -> [(dive: Dive, siteName: String?)] in
            let dives: [Dive]
            if ids.isEmpty {
                dives = try Dive.order(Column("start_time_unix").desc).fetchAll(db)
            } else {
                dives = try Dive.filter(ids.contains(Column("id")))
                    .order(Column("start_time_unix").desc)
                    .fetchAll(db)
            }

            // Bulk-fetch site names
            let siteIds = Set(dives.compactMap(\.siteId))
            let sites: [String: String]
            if siteIds.isEmpty {
                sites = [:]
            } else {
                let siteRows = try Site.filter(siteIds.contains(Column("id"))).fetchAll(db)
                sites = Dictionary(uniqueKeysWithValues: siteRows.map { ($0.id, $0.name) })
            }

            return dives.map { dive in
                (dive: dive, siteName: dive.siteId.flatMap { sites[$0] })
            }
        }

        var csv = "date,site,max_depth_m,duration_min,bottom_time_min,"
            + "min_temp_c,max_temp_c,is_ccr,deco_required,cns_percent,notes\n"

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]

        for row in rows {
            let dive = row.dive
            let date = dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(dive.startTimeUnix)))
            let site = csvEscape(row.siteName ?? "")
            let maxDepth = String(format: "%.1f", dive.maxDepthM)
            let duration = String((dive.endTimeUnix - dive.startTimeUnix) / 60)
            let bottomTime = String(dive.bottomTimeSec / 60)
            let minTemp = dive.minTempC.map { String(format: "%.1f", $0) } ?? ""
            let maxTemp = dive.maxTempC.map { String(format: "%.1f", $0) } ?? ""
            let isCcr = dive.isCcr ? "true" : "false"
            let deco = dive.decoRequired ? "true" : "false"
            let cns = String(format: "%.0f", dive.cnsPercent)
            let notes = csvEscape(dive.notes ?? "")

            csv += "\(date),\(site),\(maxDepth),\(duration),"
                + "\(bottomTime),\(minTemp),\(maxTemp),"
                + "\(isCcr),\(deco),\(cns),\(notes)\n"
        }

        return Data(csv.utf8)
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private func fetchRelations(for dives: [Dive], in db: Database) throws -> [ExportDive] {
        guard !dives.isEmpty else { return [] }

        let diveIds = Set(dives.map(\.id))

        let allTags = try DiveTag
            .filter(diveIds.contains(Column("dive_id"))).fetchAll(db)
        let allTeammates = try DiveTeammate
            .filter(diveIds.contains(Column("dive_id"))).fetchAll(db)
        let allEquipment = try DiveEquipment
            .filter(diveIds.contains(Column("dive_id"))).fetchAll(db)
        let allSamples = try DiveSample
            .filter(diveIds.contains(Column("dive_id")))
            .order(Column("t_sec")).fetchAll(db)
        let allSegments = try Segment
            .filter(diveIds.contains(Column("dive_id")))
            .order(Column("start_t_sec")).fetchAll(db)

        let segmentIds = Set(allSegments.map(\.id))
        let allSegmentTags = segmentIds.isEmpty
            ? [SegmentTag]()
            : try SegmentTag
                .filter(segmentIds.contains(Column("segment_id")))
                .fetchAll(db)

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
