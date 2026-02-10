import Foundation
import GRDB

/// Result of a Shearwater Cloud `.db` file import.
public struct ShearwaterCloudImportResult: Equatable, Sendable {
    public var totalDivesInFile: Int
    public var divesImported: Int
    public var divesSkipped: Int
    public var divesMerged: Int
    public var devicesCreated: Int
    public var sitesCreated: Int
    public var teammatesCreated: Int
    /// Diagnostic: number of samples with PPO2 sensor data.
    public var samplesWithPpo2: Int = 0
}

/// Imports dive data from a Shearwater Cloud SQLite `.db` export file.
///
/// The Shearwater Cloud desktop app exports a SQLite database containing all dive
/// metadata, sites, buddies, and computed values. This service reads that foreign DB
/// and creates corresponding DivelogCore records, deduplicating by fingerprint.
/// Dives from multiple computers at the same time are merged into one record.
public final class ShearwaterCloudImportService: Sendable {
    private let database: DivelogDatabase

    public init(database: DivelogDatabase) {
        self.database = database
    }

    /// Imports dives from a Shearwater Cloud `.db` file.
    ///
    /// - Parameters:
    ///   - path: Path to the Shearwater Cloud SQLite database file.
    ///   - progress: Optional callback `(current, total)` called after each dive is processed.
    /// - Returns: Import statistics.
    public func importFromFile(at path: String, progress: ((Int, Int) -> Void)? = nil) throws -> ShearwaterCloudImportResult {
        // Open the Shearwater DB read-only
        var config = Configuration()
        config.readonly = true
        let sourceDb = try DatabaseQueue(path: path, configuration: config)

        // Read all rows from the Shearwater database
        let rows = try sourceDb.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.*, l.calculated_values_from_samples, l.data_bytes_2, l.data_bytes_1
                FROM dive_details d
                LEFT JOIN log_data l ON d.DiveId = l.log_id
                ORDER BY d.DiveDate ASC
            """)
        }

        let totalDives = rows.count
        var divesImported = 0
        var divesSkipped = 0
        var divesMerged = 0
        var devicesCreated = 0
        var sitesCreated = 0
        var teammatesCreated = 0
        var totalSamplesWithPpo2 = 0

        // Phase 1: Create entities (devices, sites, teammates) in a single write transaction
        var serialToDeviceId: [String: String] = [:]
        var siteNameToId: [String: String] = [:]
        var teammateNameToId: [String: String] = [:]

        // Collect unique values
        var uniqueSerials = Set<String>()
        var uniqueSiteNames = Set<String>()
        var siteLocationMap: [String: String] = [:]  // siteName → Location
        var uniqueTeammateNames = Set<String>()

        for row in rows {
            let serial = stringFromRow(row, column: "SerialNumber") ?? ""
            uniqueSerials.insert(serial.isEmpty ? "" : serial)

            if let siteName = stringFromRow(row, column: "Site"), !siteName.isEmpty {
                uniqueSiteNames.insert(siteName)
                if let location = stringFromRow(row, column: "Location"), !location.isEmpty {
                    siteLocationMap[siteName] = location
                }
            }

            if let buddyField = stringFromRow(row, column: "Buddy"), !buddyField.isEmpty {
                for name in buddyField.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    if !name.isEmpty {
                        uniqueTeammateNames.insert(name)
                    }
                }
            }
        }

        try database.dbQueue.write { db in
            // Create/match devices
            for serial in uniqueSerials {
                let displaySerial = serial.isEmpty ? "unknown" : serial
                let model = serial.isEmpty ? "Shearwater (Unknown)" : "Shearwater"

                // Try to find existing device by serial number
                if let existing = try Device
                    .filter(Column("serial_number") == displaySerial)
                    .fetchOne(db) {
                    serialToDeviceId[serial] = existing.id
                } else {
                    let device = Device(
                        model: model,
                        serialNumber: displaySerial,
                        firmwareVersion: ""
                    )
                    try device.insert(db)
                    serialToDeviceId[serial] = device.id
                    devicesCreated += 1
                }
            }

            // Create/match sites
            for siteName in uniqueSiteNames {
                if let existing = try Site
                    .filter(Column("name") == siteName)
                    .fetchOne(db) {
                    siteNameToId[siteName] = existing.id
                } else {
                    let site = Site(name: siteName, notes: siteLocationMap[siteName])
                    try site.insert(db)
                    siteNameToId[siteName] = site.id
                    sitesCreated += 1
                }
            }

            // Create/match teammates
            for name in uniqueTeammateNames {
                if let existing = try Teammate
                    .filter(Column("display_name") == name)
                    .fetchOne(db) {
                    teammateNameToId[name] = existing.id
                } else {
                    let teammate = Teammate(displayName: name)
                    try teammate.insert(db)
                    teammateNameToId[name] = teammate.id
                    teammatesCreated += 1
                }
            }
        }

        // Phase 2: Build per-row intermediate structures, then group for merging
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        struct ImportRow {
            let sourceIndex: Int
            let row: Row
            let serial: String
            let deviceId: String
            let fingerprint: Data
            let startTimeUnix: Int64
            let durationSec: Int32
        }

        var importRows: [ImportRow] = []

        for (index, row) in rows.enumerated() {
            guard let diveIdStr = stringFromRow(row, column: "DiveId"), !diveIdStr.isEmpty else {
                continue
            }

            let depthFt: Float? = floatFromRow(row, column: "Depth")
            let durationSec: Int32? = int32FromRow(row, column: "DiveLengthTime")

            guard let depthFt, depthFt > 0, let durationSec, durationSec > 0 else {
                continue
            }

            let fingerprint = diveIdStr.data(using: .utf8)!

            // Parse metadata for start time
            let metadata: DiveMetadata? = decodeJSON(row["data_bytes_2"] as DatabaseValue)

            let startTimeUnix: Int64
            if let metaStart = metadata?.DIVE_START_TIME, metaStart > 0 {
                startTimeUnix = metaStart
            } else if let dateStr = stringFromRow(row, column: "DiveDate"),
                      let date = dateFormatter.date(from: dateStr) {
                startTimeUnix = Int64(date.timeIntervalSince1970)
            } else {
                continue
            }

            let serial = stringFromRow(row, column: "SerialNumber") ?? ""
            let deviceId = serialToDeviceId[serial.isEmpty ? "" : serial] ?? serialToDeviceId[""]!

            importRows.append(ImportRow(
                sourceIndex: index,
                row: row,
                serial: serial,
                deviceId: deviceId,
                fingerprint: fingerprint,
                startTimeUnix: startTimeUnix,
                durationSec: durationSec
            ))
        }

        // Rows that didn't pass validation in Phase 2
        divesSkipped += (totalDives - importRows.count)

        // Phase 3: Group rows by time proximity for merging
        // Sort by start time, then group consecutive rows from different serials within 2 minutes
        let sorted = importRows.sorted { $0.startTimeUnix < $1.startTimeUnix }
        var groups: [[ImportRow]] = []
        var currentGroup: [ImportRow] = []

        for ir in sorted {
            if let last = currentGroup.last {
                let timeDiff = abs(ir.startTimeUnix - last.startTimeUnix)
                let differentSerial = ir.serial != last.serial
                if differentSerial && timeDiff <= 120 {
                    currentGroup.append(ir)
                    continue
                }
            }
            if !currentGroup.isEmpty {
                groups.append(currentGroup)
            }
            currentGroup = [ir]
        }
        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }

        // Phase 4: Import each group
        var processedRows = 0

        for group in groups {
            // Collect fingerprints for this group
            let groupFingerprints = group.map(\.fingerprint)

            // Check if ALL fingerprints already exist in dive_source_fingerprints
            let allExist = try database.dbQueue.read { db -> Bool in
                for fp in groupFingerprints {
                    let exists = try DiveSourceFingerprint
                        .filter(Column("fingerprint") == fp)
                        .fetchCount(db) > 0
                    if !exists { return false }
                }
                return true
            }

            if allExist {
                divesSkipped += group.count
                processedRows += group.count
                for _ in group {
                    progress?(processedRows, totalDives)
                }
                continue
            }

            // Check if any fingerprint partially exists (partial merge case)
            let existingFp = try database.dbQueue.read { db -> DiveSourceFingerprint? in
                for fp in groupFingerprints {
                    if let existing = try DiveSourceFingerprint
                        .filter(Column("fingerprint") == fp)
                        .fetchOne(db) {
                        return existing
                    }
                }
                return nil
            }

            // Also check legacy dives.fingerprint column for backward compat
            let legacyExists = try database.dbQueue.read { db -> Bool in
                for fp in groupFingerprints {
                    let exists = try Dive
                        .filter(Column("fingerprint") == fp)
                        .fetchCount(db) > 0
                    if exists { return true }
                }
                return false
            }

            if legacyExists && existingFp == nil {
                // Legacy dedup — these dives exist but don't have source fingerprints yet
                divesSkipped += group.count
                processedRows += group.count
                for _ in group {
                    progress?(processedRows, totalDives)
                }
                continue
            }

            if let existingFpRecord = existingFp {
                // Partial merge: add new samples and fingerprints to existing dive
                let existingDiveId = existingFpRecord.diveId
                try database.dbQueue.write { db in
                    for ir in group {
                        // Skip if this specific fingerprint already exists
                        let fpExists = try DiveSourceFingerprint
                            .filter(Column("fingerprint") == ir.fingerprint)
                            .fetchCount(db) > 0
                        if fpExists { continue }

                        // Parse samples from this row
                        let parsedInfo = self.parseRow(ir.row, dateFormatter: dateFormatter,
                                                       calcValues: self.decodeJSON(ir.row["calculated_values_from_samples"] as DatabaseValue),
                                                       metadata: self.decodeJSON(ir.row["data_bytes_2"] as DatabaseValue))

                        // Insert new fingerprint
                        try DiveSourceFingerprint(
                            diveId: existingDiveId,
                            deviceId: ir.deviceId,
                            fingerprint: ir.fingerprint
                        ).insert(db)

                        // Insert samples with this device_id
                        for sample in parsedInfo.samples {
                            try DiveSample(
                                diveId: existingDiveId,
                                deviceId: ir.deviceId,
                                tSec: sample.tSec,
                                depthM: sample.depthM,
                                tempC: sample.tempC,
                                setpointPpo2: sample.setpointPpo2,
                                ceilingM: sample.ceilingM,
                                gf99: sample.gf99,
                                ppo2_1: sample.ppo2_1,
                                ppo2_2: sample.ppo2_2,
                                ppo2_3: sample.ppo2_3,
                                cns: sample.cns,
                                tankPressure1Bar: sample.tankPressure1Bar,
                                tankPressure2Bar: sample.tankPressure2Bar,
                                ttsSec: sample.ttsSec,
                                ndlSec: sample.ndlSec,
                                decoStopDepthM: sample.decoStopDepthM,
                                rbtSec: sample.rbtSec,
                                gasmixIndex: sample.gasmixIndex
                            ).insert(db)
                        }

                        divesMerged += 1
                    }
                }
                processedRows += group.count
                for _ in group {
                    progress?(processedRows, totalDives)
                }
                continue
            }

            // New dive (possibly merged from multiple rows)
            let groupId: String? = group.count > 1 ? UUID().uuidString : nil

            // Parse all rows in this group
            struct RowParseResult {
                let ir: ImportRow
                let parsedInfo: ParseRowResult
            }
            var parseResults: [RowParseResult] = []

            for ir in group {
                let calcValues: CalculatedValues? = decodeJSON(ir.row["calculated_values_from_samples"] as DatabaseValue)
                let metadata: DiveMetadata? = decodeJSON(ir.row["data_bytes_2"] as DatabaseValue)
                let parsedInfo = parseRow(ir.row, dateFormatter: dateFormatter, calcValues: calcValues, metadata: metadata)
                parseResults.append(RowParseResult(ir: ir, parsedInfo: parsedInfo))
            }

            // Merge metadata across group
            let mergedStartTime = group.map(\.startTimeUnix).min()!
            let mergedEndTime = group.map { $0.startTimeUnix + Int64($0.durationSec) }.max()!
            let mergedMaxDepth = parseResults.map(\.parsedInfo.maxDepthM).max()!
            let mergedBottomTime = parseResults.map(\.parsedInfo.bottomTimeSec).max()!
            let mergedIsCcr = parseResults.contains { $0.parsedInfo.isCcr }
            let mergedDecoRequired = parseResults.contains { $0.parsedInfo.decoRequired }

            // Use primary device (first CCR or first) for avgDepth
            let primaryResult = parseResults.first(where: { $0.parsedInfo.isCcr }) ?? parseResults[0]
            let primaryIr = primaryResult.ir

            // Merge metadata: prefer non-nil from any source
            let mergedNotes = parseResults.compactMap(\.parsedInfo.notes).first
            let mergedMinTempC = parseResults.compactMap(\.parsedInfo.minTempC).min()
            let mergedMaxTempC = parseResults.compactMap(\.parsedInfo.maxTempC).max()
            let mergedAvgTempC = parseResults.compactMap(\.parsedInfo.avgTempC).first
            let mergedEndGf99 = parseResults.compactMap(\.parsedInfo.endGf99).first
            let mergedGfLow = parseResults.compactMap(\.parsedInfo.gfLow).first
            let mergedGfHigh = parseResults.compactMap(\.parsedInfo.gfHigh).first
            let mergedDecoModel = parseResults.compactMap(\.parsedInfo.decoModel).first
            let mergedSalinity = parseResults.compactMap(\.parsedInfo.salinity).first
            let mergedSurfacePressure = parseResults.compactMap(\.parsedInfo.surfacePressureBar).first
            let mergedLat = parseResults.compactMap(\.parsedInfo.lat).first
            let mergedLon = parseResults.compactMap(\.parsedInfo.lon).first
            let mergedEnvironment = parseResults.compactMap(\.parsedInfo.environment).first
            let mergedVisibility = parseResults.compactMap(\.parsedInfo.visibility).first
            let mergedWeather = parseResults.compactMap(\.parsedInfo.weather).first

            // Site and buddy from any row in group
            let mergedSiteId: String? = {
                for pr in parseResults {
                    if let siteName = stringFromRow(pr.ir.row, column: "Site"), !siteName.isEmpty {
                        return siteNameToId[siteName]
                    }
                }
                return nil
            }()

            // Computer dive number
            let computerDiveNumber: Int? = {
                for pr in parseResults {
                    if let n = pr.parsedInfo.computerDiveNumber { return n }
                }
                return nil
            }()

            let diveId = UUID().uuidString
            let dive = Dive(
                id: diveId,
                deviceId: primaryIr.deviceId,
                startTimeUnix: mergedStartTime,
                endTimeUnix: mergedEndTime,
                maxDepthM: mergedMaxDepth,
                avgDepthM: primaryResult.parsedInfo.avgDepthM,
                bottomTimeSec: mergedBottomTime,
                isCcr: mergedIsCcr,
                decoRequired: mergedDecoRequired,
                siteId: mergedSiteId,
                computerDiveNumber: computerDiveNumber,
                notes: mergedNotes,
                minTempC: mergedMinTempC,
                maxTempC: mergedMaxTempC,
                avgTempC: mergedAvgTempC,
                endGf99: mergedEndGf99,
                gfLow: mergedGfLow,
                gfHigh: mergedGfHigh,
                decoModel: mergedDecoModel,
                salinity: mergedSalinity,
                surfacePressureBar: mergedSurfacePressure,
                lat: mergedLat,
                lon: mergedLon,
                groupId: groupId,
                environment: mergedEnvironment,
                visibility: mergedVisibility,
                weather: mergedWeather
            )

            // Collect all teammate IDs from all rows in group
            var teammateIds = Set<String>()
            for pr in parseResults {
                if let buddyField = stringFromRow(pr.ir.row, column: "Buddy"), !buddyField.isEmpty {
                    for name in buddyField.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        if let id = teammateNameToId[name] {
                            teammateIds.insert(id)
                        }
                    }
                }
            }

            try database.dbQueue.write { db in
                // TOCTOU double-check inside write transaction
                for fp in groupFingerprints {
                    let exists = try DiveSourceFingerprint
                        .filter(Column("fingerprint") == fp)
                        .fetchCount(db) > 0
                    if exists { return }
                    // Also check legacy
                    let legacyExists = try Dive
                        .filter(Column("fingerprint") == fp)
                        .fetchCount(db) > 0
                    if legacyExists { return }
                }

                try dive.insert(db)

                for teammateId in teammateIds {
                    try DiveTeammate(diveId: diveId, teammateId: teammateId).insert(db)
                }

                // Insert source fingerprints + samples from each device
                // Collect gas mixes across all devices, deduplicating by (o2, he, usage)
                struct MixKey: Hashable {
                    let o2: Int  // o2Fraction * 1000 as integer for reliable hashing
                    let he: Int
                    let usage: String?
                }
                var seenMixes = Set<MixKey>()
                var uniqueMixes: [ParsedGasMix] = []

                for pr in parseResults {
                    try DiveSourceFingerprint(
                        diveId: diveId,
                        deviceId: pr.ir.deviceId,
                        fingerprint: pr.ir.fingerprint
                    ).insert(db)

                    for sample in pr.parsedInfo.samples {
                        try DiveSample(
                            diveId: diveId,
                            deviceId: pr.ir.deviceId,
                            tSec: sample.tSec,
                            depthM: sample.depthM,
                            tempC: sample.tempC,
                            setpointPpo2: sample.setpointPpo2,
                            ceilingM: sample.ceilingM,
                            gf99: sample.gf99,
                            ppo2_1: sample.ppo2_1,
                            ppo2_2: sample.ppo2_2,
                            ppo2_3: sample.ppo2_3,
                            cns: sample.cns,
                            tankPressure1Bar: sample.tankPressure1Bar,
                            tankPressure2Bar: sample.tankPressure2Bar,
                            ttsSec: sample.ttsSec,
                            ndlSec: sample.ndlSec,
                            decoStopDepthM: sample.decoStopDepthM,
                            rbtSec: sample.rbtSec,
                            gasmixIndex: sample.gasmixIndex
                        ).insert(db)
                    }

                    for mix in pr.parsedInfo.gasMixes {
                        let key = MixKey(o2: Int(mix.o2Fraction * 1000),
                                         he: Int(mix.heFraction * 1000),
                                         usage: mix.usage)
                        if seenMixes.insert(key).inserted {
                            uniqueMixes.append(mix)
                        }
                    }
                }

                // Insert deduplicated gas mixes with sequential indices
                for (idx, mix) in uniqueMixes.enumerated() {
                    try GasMix(
                        diveId: diveId,
                        mixIndex: idx,
                        o2Fraction: mix.o2Fraction,
                        heFraction: mix.heFraction,
                        usage: mix.usage
                    ).insert(db)
                }
            }

            // Count PPO2 samples from all parse results (outside the write transaction)
            let ppo2Count = parseResults.reduce(0) { acc, pr in
                acc + pr.parsedInfo.samples.filter { $0.ppo2_1 != nil || $0.ppo2_2 != nil || $0.ppo2_3 != nil }.count
            }
            totalSamplesWithPpo2 += ppo2Count

            divesImported += 1
            if group.count > 1 {
                // Count extra rows consumed by merging (group.count - 1)
                divesMerged += group.count - 1
            }
            processedRows += group.count
            for _ in group {
                progress?(processedRows, totalDives)
            }
        }

        return ShearwaterCloudImportResult(
            totalDivesInFile: totalDives,
            divesImported: divesImported,
            divesSkipped: divesSkipped,
            divesMerged: divesMerged,
            devicesCreated: devicesCreated,
            sitesCreated: sitesCreated,
            teammatesCreated: teammatesCreated,
            samplesWithPpo2: totalSamplesWithPpo2
        )
    }

    // MARK: - Row Parsing

    struct ParseRowResult {
        var maxDepthM: Float
        var avgDepthM: Float
        var bottomTimeSec: Int32
        var isCcr: Bool
        var decoRequired: Bool
        var samples: [ParsedSample]
        var gasMixes: [ParsedGasMix]
        var notes: String?
        var minTempC: Float?
        var maxTempC: Float?
        var avgTempC: Float?
        var endGf99: Float?
        var gfLow: Int?
        var gfHigh: Int?
        var decoModel: String?
        var salinity: String?
        var surfacePressureBar: Float?
        var lat: Double?
        var lon: Double?
        var environment: String?
        var visibility: String?
        var weather: String?
        var computerDiveNumber: Int?
    }

    private func parseRow(_ row: Row, dateFormatter: DateFormatter,
                          calcValues: CalculatedValues?, metadata: DiveMetadata?) -> ParseRowResult {
        let depthFt = floatFromRow(row, column: "Depth") ?? 0
        let durationSec = int32FromRow(row, column: "DiveLengthTime") ?? 0

        // Try parsing binary dive data via libdivecomputer
        let binaryBlob: Data? = blobOrTextFromRow(row, column: "data_bytes_1")
        let parsedDive: ParsedDive? = binaryBlob.flatMap { Self.parseBinaryDiveData($0) }

        let maxDepthM: Float
        let avgDepthM: Float
        let bottomTimeSec: Int32
        let isCcr: Bool
        let decoRequired: Bool
        let samples: [ParsedSample]
        var gasMixes: [ParsedGasMix] = []

        if let parsed = parsedDive, parsed.maxDepthM > 0 {
            maxDepthM = parsed.maxDepthM
            avgDepthM = parsed.avgDepthM > 0 ? parsed.avgDepthM : parsed.maxDepthM * 0.5
            bottomTimeSec = parsed.bottomTimeSec > 0 ? parsed.bottomTimeSec : durationSec
            isCcr = parsed.isCcr
            decoRequired = parsed.decoRequired
            samples = parsed.samples
            gasMixes = parsed.gasMixes
        } else {
            maxDepthM = depthFt * 0.3048
            let avgDepthFt: Float
            if let nativeAvg = floatFromRow(row, column: "AverageDepth"), nativeAvg > 0 {
                avgDepthFt = nativeAvg
            } else {
                avgDepthFt = calcValues?.AverageDepth ?? depthFt * 0.5
            }
            avgDepthM = avgDepthFt * 0.3048
            bottomTimeSec = durationSec
            isCcr = false
            decoRequired = (calcValues?.MaxDecoObligation ?? 0) > 0
            samples = []
        }

        // Notes
        let notes = stringFromRow(row, column: "Notes")

        // Temperature: priority libdivecomputer → native columns → calculated_values
        let minTempC: Float? = {
            if let parsed = parsedDive, let t = parsed.minTempC { return t }
            if let native = floatFromRow(row, column: "MinTemp"), native != 0 {
                return (native - 32) * 5 / 9  // °F → °C
            }
            if let calc = calcValues?.MinTemp, calc != 0 {
                return (calc - 32) * 5 / 9
            }
            return nil
        }()

        let maxTempC: Float? = {
            if let parsed = parsedDive, let t = parsed.maxTempC { return t }
            if let native = floatFromRow(row, column: "MaxTemp"), native != 0 {
                return (native - 32) * 5 / 9
            }
            if let calc = calcValues?.MaxTemp, calc != 0 {
                return (calc - 32) * 5 / 9
            }
            return nil
        }()

        let avgTempC: Float? = {
            if let parsed = parsedDive, let t = parsed.avgTempC { return t }
            if let native = floatFromRow(row, column: "AverageTemp"), native != 0 {
                return (native - 32) * 5 / 9
            }
            return nil
        }()

        // End GF99: native column is often 0, fall back to calculated_values JSON
        let endGf99: Float? = {
            if let native = floatFromRow(row, column: "EndGF99"), native > 0 { return native }
            if let cv = calcValues?.EndGF99, cv > 0 { return cv }
            return nil
        }()

        // GF settings from parsed data
        let gfLow = parsedDive?.gfLow
        let gfHigh = parsedDive?.gfHigh
        let decoModel = parsedDive?.decoModel
        let salinity = parsedDive?.salinity
        let surfacePressureBar = parsedDive?.surfacePressureBar

        // GPS from GnssEntryLocation "lat,lon"
        let (lat, lon): (Double?, Double?) = {
            guard let gnss = stringFromRow(row, column: "GnssEntryLocation"), !gnss.isEmpty else {
                return (parsedDive?.lat, parsedDive?.lon)
            }
            let parts = gnss.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2,
                  let lat = Double(parts[0]),
                  let lon = Double(parts[1]) else {
                return (parsedDive?.lat, parsedDive?.lon)
            }
            return (lat, lon)
        }()

        // Environment fields
        let environment = stringFromRow(row, column: "Environment")
        let visibility = stringFromRow(row, column: "Visibility")
        let weather = stringFromRow(row, column: "Weather")

        // Computer dive number
        let computerDiveNumber: Int?
        if let metaNum = metadata?.DIVE_NUMBER_KEY {
            computerDiveNumber = metaNum
        } else if let nativeNum = int32FromRow(row, column: "DiveNumber") {
            computerDiveNumber = Int(nativeNum)
        } else {
            computerDiveNumber = nil
        }

        return ParseRowResult(
            maxDepthM: maxDepthM,
            avgDepthM: avgDepthM,
            bottomTimeSec: bottomTimeSec,
            isCcr: isCcr,
            decoRequired: decoRequired,
            samples: samples,
            gasMixes: gasMixes,
            notes: notes,
            minTempC: minTempC,
            maxTempC: maxTempC,
            avgTempC: avgTempC,
            endGf99: endGf99,
            gfLow: gfLow,
            gfHigh: gfHigh,
            decoModel: decoModel,
            salinity: salinity,
            surfacePressureBar: surfacePressureBar,
            lat: lat,
            lon: lon,
            environment: environment,
            visibility: visibility,
            weather: weather,
            computerDiveNumber: computerDiveNumber
        )
    }

    // MARK: - Private Helpers

    /// Safely extract a String from a Row column regardless of SQLite storage class.
    /// Returns nil if the column doesn't exist in the row.
    private func stringFromRow(_ row: Row, column: String) -> String? {
        guard row.hasColumn(column) else { return nil }
        let dbValue: DatabaseValue = row[column]
        switch dbValue.storage {
        case .string(let s): return s
        case .int64(let i): return String(i)
        case .double(let d): return String(d)
        case .blob: return nil
        case .null: return nil
        }
    }

    private func floatFromRow(_ row: Row, column: String) -> Float? {
        guard row.hasColumn(column) else { return nil }
        let dbValue: DatabaseValue = row[column]
        switch dbValue.storage {
        case .double(let d): return Float(d)
        case .int64(let i): return Float(i)
        case .string(let s): return Float(s)
        case .blob, .null: return nil
        }
    }

    private func int32FromRow(_ row: Row, column: String) -> Int32? {
        guard row.hasColumn(column) else { return nil }
        let dbValue: DatabaseValue = row[column]
        switch dbValue.storage {
        case .int64(let i): return Int32(i)
        case .double(let d): return Int32(d)
        case .string(let s): return Int(s).map { Int32($0) }
        case .blob, .null: return nil
        }
    }

    /// Reads a column as Data, handling both BLOB and base64-encoded TEXT.
    private func blobOrTextFromRow(_ row: Row, column: String) -> Data? {
        guard row.hasColumn(column) else { return nil }
        let dbValue: DatabaseValue = row[column]
        switch dbValue.storage {
        case .blob(let data): return data
        case .string(let str):
            return Data(base64Encoded: str)
        case .null, .int64, .double: return nil
        }
    }

    private func decodeJSON<T: Decodable>(_ dbValue: DatabaseValue) -> T? {
        switch dbValue.storage {
        case .string(let str):
            guard let data = str.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        case .blob(let data):
            return try? JSONDecoder().decode(T.self, from: data)
        case .null, .int64, .double:
            return nil
        }
    }

    // MARK: - Binary Dive Data Parsing

    /// Parses a Shearwater binary dive blob (`data_bytes_1`) into a `ParsedDive`.
    /// Returns `nil` when LibDivecomputerFFI is not available or parsing fails.
    static func parseBinaryDiveData(_ blob: Data) -> ParsedDive? {
        #if canImport(LibDivecomputerFFI)
        return _parseBinaryDiveDataImpl(blob)
        #else
        return nil
        #endif
    }
}

#if canImport(LibDivecomputerFFI)
import LibDivecomputerFFI
import CZlibHelper

private func _parseBinaryDiveDataImpl(_ blob: Data) -> ParsedDive? {
    guard blob.count > 14 else { return nil }

    // Shearwater Cloud stores data_bytes_1 as:
    //   [4-byte LE decompressed size] [gzip compressed data]
    // Detect gzip magic (1f 8b) at offset 4
    let data: Data
    if blob.count > 14 && blob[4] == 0x1f && blob[5] == 0x8b {
        guard let decompressed = gunzipData(blob.subdata(in: 4..<blob.count)) else {
            return nil
        }
        data = decompressed
    } else if blob[0] == 0x1f && blob[1] == 0x8b {
        guard let decompressed = gunzipData(blob) else {
            return nil
        }
        data = decompressed
    } else {
        data = blob
    }

    return _tryParseShearwaterBlob(data)
}

/// Decompresses gzip data using the real zlib library (inflateInit2 with windowBits=31).
private func gunzipData(_ gzData: Data) -> Data? {
    guard gzData.count > 18,
          gzData[0] == 0x1f, gzData[1] == 0x8b
    else { return nil }

    let isize = gzData.withUnsafeBytes { buf -> UInt32 in
        buf.baseAddress!.advanced(by: gzData.count - 4).loadUnaligned(as: UInt32.self)
    }
    var bufferSize = max(Int(isize), 65536)
    bufferSize = min(bufferSize, 10 * 1024 * 1024)

    let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { destinationBuffer.deallocate() }

    let result = gzData.withUnsafeBytes { rawBuf -> Int32 in
        guard let src = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return -1 }
        return czlib_gunzip(src, Int32(gzData.count), destinationBuffer, Int32(bufferSize))
    }

    if result == -2 {
        let bigSize = bufferSize * 4
        let bigBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bigSize)
        defer { bigBuffer.deallocate() }
        let retry = gzData.withUnsafeBytes { rawBuf -> Int32 in
            guard let src = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return czlib_gunzip(src, Int32(gzData.count), bigBuffer, Int32(bigSize))
        }
        guard retry > 0 else { return nil }
        return Data(bytes: bigBuffer, count: Int(retry))
    }

    guard result > 0 else { return nil }
    return Data(bytes: destinationBuffer, count: Int(result))
}

private func _tryParseShearwaterBlob(_ blob: Data) -> ParsedDive? {
    var ctx: OpaquePointer?
    guard dc_context_new(&ctx) == DC_STATUS_SUCCESS, let context = ctx else { return nil }
    defer { dc_context_free(context) }

    guard let descriptor = findShearwaterDescriptor(context: context) else { return nil }
    defer { dc_descriptor_free(descriptor) }

    return blob.withUnsafeBytes { rawBuf -> ParsedDive? in
        guard let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return nil }

        var parser: OpaquePointer?
        let status = dc_parser_new2(&parser, context, descriptor, ptr, blob.count)
        guard status == DC_STATUS_SUCCESS, let p = parser else {
            return nil
        }
        defer { dc_parser_destroy(p) }

        // Extract datetime
        var datetime = dc_datetime_t()
        let dtStatus = dc_parser_get_datetime(p, &datetime)
        let startTimeUnix: Int64 = {
            guard dtStatus == DC_STATUS_SUCCESS else { return 0 }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            var components = DateComponents()
            components.year = Int(datetime.year)
            components.month = Int(datetime.month)
            components.day = Int(datetime.day)
            components.hour = Int(datetime.hour)
            components.minute = Int(datetime.minute)
            components.second = Int(datetime.second)
            return Int64(cal.date(from: components)?.timeIntervalSince1970 ?? 0)
        }()

        // Extract fields
        var maxDepth: Double = 0
        dc_parser_get_field(p, DC_FIELD_MAXDEPTH, 0, &maxDepth)

        var avgDepth: Double = 0
        dc_parser_get_field(p, DC_FIELD_AVGDEPTH, 0, &avgDepth)

        var diveTime: UInt32 = 0
        dc_parser_get_field(p, DC_FIELD_DIVETIME, 0, &diveTime)

        var diveMode: dc_divemode_t = DC_DIVEMODE_OC
        dc_parser_get_field(p, DC_FIELD_DIVEMODE, 0, &diveMode)
        let isCcr = diveMode == DC_DIVEMODE_CCR || diveMode == DC_DIVEMODE_SCR

        // Temperature fields
        var minTemp: Double = 0
        let minTempStatus = dc_parser_get_field(p, DC_FIELD_TEMPERATURE_MINIMUM, 0, &minTemp)

        var maxTemp: Double = 0
        let maxTempStatus = dc_parser_get_field(p, DC_FIELD_TEMPERATURE_MAXIMUM, 0, &maxTemp)

        // Deco model & GF settings
        var decomodel = dc_decomodel_t()
        let decoStatus = dc_parser_get_field(p, DC_FIELD_DECOMODEL, 0, &decomodel)
        var gfLow: Int?, gfHigh: Int?, decoModelStr: String?
        if decoStatus == DC_STATUS_SUCCESS {
            switch decomodel.type {
            case DC_DECOMODEL_BUHLMANN: decoModelStr = "buhlmann"
            case DC_DECOMODEL_VPM: decoModelStr = "vpm"
            case DC_DECOMODEL_RGBM: decoModelStr = "rgbm"
            default: break
            }
            if decomodel.type == DC_DECOMODEL_BUHLMANN {
                gfLow = Int(decomodel.params.gf.low)
                gfHigh = Int(decomodel.params.gf.high)
            }
        }

        // Gas mixes
        var gasmixCount: UInt32 = 0
        dc_parser_get_field(p, DC_FIELD_GASMIX_COUNT, 0, &gasmixCount)
        var parsedGasMixes: [ParsedGasMix] = []
        for i in 0..<Int(gasmixCount) {
            var mix = dc_gasmix_t()
            if dc_parser_get_field(p, DC_FIELD_GASMIX, UInt32(i), &mix) == DC_STATUS_SUCCESS {
                let usage: String? = {
                    switch mix.usage {
                    case DC_USAGE_OXYGEN: return "oxygen"
                    case DC_USAGE_DILUENT: return "diluent"
                    case DC_USAGE_SIDEMOUNT: return "sidemount"
                    default: return nil
                    }
                }()
                parsedGasMixes.append(ParsedGasMix(
                    index: i, o2Fraction: Float(mix.oxygen),
                    heFraction: Float(mix.helium), usage: usage
                ))
            }
        }

        // Salinity
        var salinity = dc_salinity_t()
        let salStatus = dc_parser_get_field(p, DC_FIELD_SALINITY, 0, &salinity)
        let salinityStr: String? = {
            guard salStatus == DC_STATUS_SUCCESS else { return nil }
            switch salinity.type {
            case DC_WATER_FRESH: return "fresh"
            case DC_WATER_SALT: return "salt"
            default: return nil
            }
        }()

        // Atmospheric pressure
        var atmospheric: Double = 0
        let atmStatus = dc_parser_get_field(p, DC_FIELD_ATMOSPHERIC, 0, &atmospheric)

        // Parse samples
        var sampleContext = ShearwaterSampleContext()
        withUnsafeMutablePointer(to: &sampleContext) { sPtr in
            _ = dc_parser_samples_foreach(p, shearwaterSampleCallback, sPtr)
        }

        // Commit the final in-progress sample
        if sampleContext.currentTime > 0 || !sampleContext.samples.isEmpty {
            sampleContext.commitCurrentSample()
        }

        #if DEBUG
        let ppo2Samples = sampleContext.samples.filter { $0.ppo2_1 != nil || $0.ppo2_2 != nil || $0.ppo2_3 != nil }.count
        NSLog("[ShearwaterParse] PPO2 callbacks: \(sampleContext.ppo2CallbackCount), samples with PPO2: \(ppo2Samples)/\(sampleContext.samples.count), isCCR: \(isCcr)")
        #endif

        let endTimeUnix = startTimeUnix + Int64(diveTime)

        return ParsedDive(
            startTimeUnix: startTimeUnix,
            endTimeUnix: endTimeUnix,
            maxDepthM: Float(maxDepth),
            avgDepthM: Float(avgDepth),
            bottomTimeSec: Int32(diveTime),
            isCcr: isCcr,
            decoRequired: sampleContext.maxCeiling > 0,
            samples: sampleContext.samples,
            minTempC: minTempStatus == DC_STATUS_SUCCESS ? Float(minTemp) : nil,
            maxTempC: maxTempStatus == DC_STATUS_SUCCESS ? Float(maxTemp) : nil,
            gfLow: gfLow,
            gfHigh: gfHigh,
            decoModel: decoModelStr,
            salinity: salinityStr,
            surfacePressureBar: atmStatus == DC_STATUS_SUCCESS ? Float(atmospheric) : nil,
            gasMixes: parsedGasMixes
        )
    }
}

/// Finds the first Shearwater Petrel descriptor from libdivecomputer's built-in list.
private func findShearwaterDescriptor(context: OpaquePointer) -> OpaquePointer? {
    var iterator: OpaquePointer?
    guard dc_descriptor_iterator_new(&iterator, context) == DC_STATUS_SUCCESS,
          let iter = iterator else { return nil }
    defer { dc_iterator_free(iter) }

    var descriptor: OpaquePointer?
    while dc_iterator_next(iter, &descriptor) == DC_STATUS_SUCCESS {
        guard let desc = descriptor else { continue }
        let family = dc_descriptor_get_type(desc)
        if family == DC_FAMILY_SHEARWATER_PETREL {
            return desc
        }
        dc_descriptor_free(desc)
    }
    return nil
}

// MARK: - Sample Callback (for Shearwater Cloud binary parsing)

private struct ShearwaterSampleContext {
    var samples: [ParsedSample] = []
    var currentTime: Int32 = 0
    var currentDepth: Float = 0
    var currentTemp: Float = 0
    var currentSetpoint: Float?
    var currentCeiling: Float?
    var currentGf99: Float?
    var currentPpo2_1: Float?
    var currentPpo2_2: Float?
    var currentPpo2_3: Float?
    var currentCns: Float?
    var currentTankPressure1: Float?
    var currentTankPressure2: Float?
    var currentTtsSec: Int?
    var currentNdlSec: Int?
    var currentDecoStopDepthM: Float?
    var currentRbtSec: Int?
    var currentGasmixIndex: Int?
    var maxCeiling: Float = 0
    var ppo2CallbackCount: Int = 0

    mutating func commitCurrentSample() {
        samples.append(ParsedSample(
            tSec: currentTime,
            depthM: currentDepth,
            tempC: currentTemp,
            setpointPpo2: currentSetpoint,
            ceilingM: currentCeiling,
            gf99: currentGf99,
            ppo2_1: currentPpo2_1,
            ppo2_2: currentPpo2_2,
            ppo2_3: currentPpo2_3,
            cns: currentCns,
            tankPressure1Bar: currentTankPressure1,
            tankPressure2Bar: currentTankPressure2,
            ttsSec: currentTtsSec,
            ndlSec: currentNdlSec,
            decoStopDepthM: currentDecoStopDepthM,
            rbtSec: currentRbtSec,
            gasmixIndex: currentGasmixIndex
        ))
    }

    mutating func resetPerSampleFields() {
        currentSetpoint = nil
        currentCeiling = nil
        currentGf99 = nil
        currentPpo2_1 = nil
        currentPpo2_2 = nil
        currentPpo2_3 = nil
        currentCns = nil
        currentTankPressure1 = nil
        currentTankPressure2 = nil
        currentTtsSec = nil
        currentNdlSec = nil
        currentDecoStopDepthM = nil
        currentRbtSec = nil
        currentGasmixIndex = nil
    }
}

private func shearwaterSampleCallback(
    _ type: dc_sample_type_t,
    _ value: UnsafePointer<dc_sample_value_t>?,
    _ userdata: UnsafeMutableRawPointer?
) {
    guard let userdata, let value else { return }
    let ctx = userdata.assumingMemoryBound(to: ShearwaterSampleContext.self)
    let v = value.pointee

    switch type {
    case DC_SAMPLE_TIME:
        if ctx.pointee.currentTime > 0 || !ctx.pointee.samples.isEmpty {
            ctx.pointee.commitCurrentSample()
        }
        // libdivecomputer reports time in milliseconds; convert to seconds
        ctx.pointee.currentTime = Int32(v.time / 1000)
        ctx.pointee.resetPerSampleFields()

    case DC_SAMPLE_DEPTH:
        ctx.pointee.currentDepth = Float(v.depth)

    case DC_SAMPLE_TEMPERATURE:
        ctx.pointee.currentTemp = Float(v.temperature)

    case DC_SAMPLE_SETPOINT:
        ctx.pointee.currentSetpoint = Float(v.setpoint)

    case DC_SAMPLE_PPO2:
        let ppo2 = v.ppo2
        ctx.pointee.ppo2CallbackCount += 1
        switch ppo2.sensor {
        case 0: ctx.pointee.currentPpo2_1 = Float(ppo2.value)
        case 1: ctx.pointee.currentPpo2_2 = Float(ppo2.value)
        case 2: ctx.pointee.currentPpo2_3 = Float(ppo2.value)
        default:
            // DC_SENSOR_NONE (0xFFFFFFFF): computer's averaged/voted PPO2.
            // Store as ppo2_1 when per-sensor data isn't available
            // (e.g. Shearwater with default calibration).
            if ctx.pointee.currentPpo2_1 == nil {
                ctx.pointee.currentPpo2_1 = Float(ppo2.value)
            }
        }

    case DC_SAMPLE_CNS:
        ctx.pointee.currentCns = Float(v.cns)

    case DC_SAMPLE_PRESSURE:
        let press = v.pressure
        let bar = Float(press.value)
        switch press.tank {
        case 0: ctx.pointee.currentTankPressure1 = bar
        case 1: ctx.pointee.currentTankPressure2 = bar
        default: break
        }

    case DC_SAMPLE_RBT:
        ctx.pointee.currentRbtSec = Int(v.rbt)

    case DC_SAMPLE_GASMIX:
        ctx.pointee.currentGasmixIndex = Int(v.gasmix)

    case DC_SAMPLE_DECO:
        let deco = v.deco
        ctx.pointee.currentCeiling = Float(deco.depth)
        ctx.pointee.currentTtsSec = Int(deco.tts)
        if deco.type == DC_DECO_NDL.rawValue {
            ctx.pointee.currentNdlSec = Int(deco.time)
        }
        ctx.pointee.currentDecoStopDepthM = Float(deco.depth)
        if Float(deco.depth) > ctx.pointee.maxCeiling {
            ctx.pointee.maxCeiling = Float(deco.depth)
        }

    default:
        break
    }
}

#endif

// MARK: - Internal JSON Structs

private struct CalculatedValues: Decodable {
    let AverageDepth: Float?
    let MinTemp: Float?
    let MaxTemp: Float?
    let MaxDecoObligation: Float?
    let EndGF99: Float?
}

private struct DiveMetadata: Decodable {
    let DIVE_NUMBER_KEY: Int?
    let DIVE_START_TIME: Int64?
}
