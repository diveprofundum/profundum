import Foundation
import GRDB

/// Service for populating the database with sample data for development and testing.
public final class SampleDataService: Sendable {
    private let database: DivelogDatabase
    private let diveService: DiveService

    public init(database: DivelogDatabase) {
        self.database = database
        self.diveService = DiveService(database: database)
    }

    /// Check if sample data has already been loaded.
    public func hasSampleData() throws -> Bool {
        try database.dbQueue.read { db in
            let count = try Device.fetchCount(db)
            return count > 0
        }
    }

    /// Populate the database with sample data.
    /// This includes devices, sites, buddies, equipment, and dives with samples.
    public func loadSampleData() throws {
        // Create devices
        let devices = try createSampleDevices()

        // Create sites
        let sites = try createSampleSites()

        // Create buddies
        let buddies = try createSampleBuddies()

        // Create equipment
        let equipment = try createSampleEquipment()

        // Create dives with samples
        try createSampleDives(
            devices: devices,
            sites: sites,
            buddies: buddies,
            equipment: equipment
        )
    }

    /// Remove all sample data from the database.
    public func clearAllData() throws {
        try database.dbQueue.write { db in
            // Delete in order respecting foreign keys
            try db.execute(sql: "DELETE FROM calculated_fields")
            try db.execute(sql: "DELETE FROM samples")
            try db.execute(sql: "DELETE FROM segments")
            try db.execute(sql: "DELETE FROM dive_tags")
            try db.execute(sql: "DELETE FROM dive_buddies")
            try db.execute(sql: "DELETE FROM dive_equipment")
            try db.execute(sql: "DELETE FROM dives")
            try db.execute(sql: "DELETE FROM formulas")
            try db.execute(sql: "DELETE FROM equipment")
            try db.execute(sql: "DELETE FROM buddies")
            try db.execute(sql: "DELETE FROM site_tags")
            try db.execute(sql: "DELETE FROM sites")
            try db.execute(sql: "DELETE FROM devices")
        }
    }

    // MARK: - Private Helpers

    private func createSampleDevices() throws -> [Device] {
        let devices = [
            Device(
                id: "device-petrel3",
                model: "Shearwater Petrel 3",
                serialNumber: "PT3-001234",
                firmwareVersion: "92",
                lastSyncUnix: Int64(Date().timeIntervalSince1970),
                isActive: true
            ),
            Device(
                id: "device-perdix2",
                model: "Shearwater Perdix 2",
                serialNumber: "PX2-005678",
                firmwareVersion: "45",
                lastSyncUnix: Int64(Date().timeIntervalSince1970),
                isActive: true
            ),
            Device(
                id: "device-descent",
                model: "Garmin Descent Mk2i",
                serialNumber: "3GV012345",
                firmwareVersion: "9.10",
                lastSyncUnix: Int64(Date().timeIntervalSince1970) - 86400,
                isActive: true
            ),
            Device(
                id: "device-old-perdix",
                model: "Shearwater Perdix",
                serialNumber: "PX-001111",
                firmwareVersion: "38",
                lastSyncUnix: Int64(Date().timeIntervalSince1970) - 86400 * 365,
                isActive: false  // Archived - sold this computer
            ),
        ]

        for device in devices {
            try diveService.saveDevice(device)
        }

        return devices
    }

    private func createSampleSites() throws -> [Site] {
        let sites = [
            Site(
                id: "site-blue-heron",
                name: "Blue Heron Bridge",
                lat: 26.7865,
                lon: -80.0519,
                notes: "Shore dive, best at slack tide. Great for macro photography."
            ),
            Site(
                id: "site-ginnie",
                name: "Ginnie Springs - Ballroom",
                lat: 29.8369,
                lon: -82.7006,
                notes: "Cave dive, requires cavern/cave cert. Crystal clear water."
            ),
            Site(
                id: "site-eagle",
                name: "Eagle Ray Alley",
                lat: 18.4207,
                lon: -64.9507,
                notes: "USVI, boat dive. Frequent eagle ray sightings."
            ),
            Site(
                id: "site-doria",
                name: "Andrea Doria",
                lat: 40.2967,
                lon: -69.8517,
                notes: "Technical wreck dive, 73m/240ft. Requires trimix and extensive planning."
            ),
        ]

        for site in sites {
            try diveService.saveSite(site, tags: tagsForSite(site))
        }

        return sites
    }

    private func tagsForSite(_ site: Site) -> [String] {
        switch site.id {
        case "site-blue-heron":
            return ["shore", "macro", "night"]
        case "site-ginnie":
            return ["cave", "freshwater", "training"]
        case "site-eagle":
            return ["boat", "reef", "caribbean"]
        case "site-doria":
            return ["wreck", "technical", "deep"]
        default:
            return []
        }
    }

    private func createSampleBuddies() throws -> [Buddy] {
        let buddies = [
            Buddy(
                id: "buddy-sarah",
                displayName: "Sarah Chen",
                contact: "sarah@example.com",
                notes: "Cave instructor, GUE Tech 2"
            ),
            Buddy(
                id: "buddy-mike",
                displayName: "Mike Rodriguez",
                contact: nil,
                notes: "Wreck diving buddy, experienced with stage bottles"
            ),
            Buddy(
                id: "buddy-emma",
                displayName: "Emma Thompson",
                contact: "emma.t@example.com",
                notes: "Underwater photographer"
            ),
        ]

        for buddy in buddies {
            try diveService.saveBuddy(buddy)
        }

        return buddies
    }

    private func createSampleEquipment() throws -> [Equipment] {
        let equipment = [
            Equipment(
                id: "equip-jj",
                name: "JJ-CCR",
                kind: "Rebreather",
                serialNumber: "JJ-2021-0456",
                serviceIntervalDays: 365,
                notes: "Primary rebreather, O2 cells replaced 2024-01"
            ),
            Equipment(
                id: "equip-al80",
                name: "AL80 Bailout",
                kind: "Cylinder",
                serialNumber: "DOT-3AL-3000-2020",
                serviceIntervalDays: 365,
                notes: "50% nitrox bailout"
            ),
            Equipment(
                id: "equip-drysuit",
                name: "Santi E.Motion+",
                kind: "Drysuit",
                serialNumber: nil,
                serviceIntervalDays: nil,
                notes: "Crushed neoprene, heated undergarment compatible"
            ),
            Equipment(
                id: "equip-light",
                name: "Light Monkey 32W LED",
                kind: "Light",
                serialNumber: "LM-32-1234",
                serviceIntervalDays: nil,
                notes: "Primary canister light"
            ),
        ]

        for item in equipment {
            try diveService.saveEquipment(item)
        }

        return equipment
    }

    private func createSampleDives(
        devices: [Device],
        sites: [Site],
        buddies: [Buddy],
        equipment: [Equipment]
    ) throws {
        let now = Date()
        let calendar = Calendar.current

        // Dive 1: Recent CCR cave dive at Ginnie Springs
        let dive1Start = calendar.date(byAdding: .day, value: -3, to: now)!
        try createCCRCaveDive(
            id: "dive-001",
            device: devices.first { $0.id == "device-petrel3" }!,
            site: sites.first { $0.id == "site-ginnie" }!,
            buddies: [buddies.first { $0.id == "buddy-sarah" }!],
            equipment: [
                equipment.first { $0.id == "equip-jj" }!,
                equipment.first { $0.id == "equip-al80" }!,
                equipment.first { $0.id == "equip-light" }!,
            ],
            startTime: dive1Start
        )

        // Dive 2: Recreational reef dive with Garmin
        let dive2Start = calendar.date(byAdding: .day, value: -7, to: now)!
        try createRecreationalDive(
            id: "dive-002",
            device: devices.first { $0.id == "device-descent" }!,
            site: sites.first { $0.id == "site-eagle" }!,
            buddies: [buddies.first { $0.id == "buddy-emma" }!],
            equipment: [],
            startTime: dive2Start
        )

        // Dive 3: Technical deco dive
        let dive3Start = calendar.date(byAdding: .day, value: -14, to: now)!
        try createTechDecoDive(
            id: "dive-003",
            device: devices.first { $0.id == "device-perdix2" }!,
            site: sites.first { $0.id == "site-doria" }!,
            buddies: [
                buddies.first { $0.id == "buddy-sarah" }!,
                buddies.first { $0.id == "buddy-mike" }!,
            ],
            equipment: [
                equipment.first { $0.id == "equip-drysuit" }!,
                equipment.first { $0.id == "equip-light" }!,
            ],
            startTime: dive3Start
        )

        // Dive 4: Night dive at Blue Heron
        let dive4Start = calendar.date(byAdding: .day, value: -21, to: now)!
        try createNightDive(
            id: "dive-004",
            device: devices.first { $0.id == "device-descent" }!,
            site: sites.first { $0.id == "site-blue-heron" }!,
            buddies: [buddies.first { $0.id == "buddy-emma" }!],
            equipment: [equipment.first { $0.id == "equip-light" }!],
            startTime: dive4Start
        )

        // Dive 5: Another cave dive (same day as dive 1, second dive)
        let dive5Start = calendar.date(byAdding: .hour, value: 3, to: dive1Start)!
        try createCCRCaveDive(
            id: "dive-005",
            device: devices.first { $0.id == "device-petrel3" }!,
            site: sites.first { $0.id == "site-ginnie" }!,
            buddies: [buddies.first { $0.id == "buddy-sarah" }!],
            equipment: [
                equipment.first { $0.id == "equip-jj" }!,
                equipment.first { $0.id == "equip-al80" }!,
                equipment.first { $0.id == "equip-light" }!,
            ],
            startTime: dive5Start
        )
    }

    // MARK: - Dive Profile Generators

    private func createCCRCaveDive(
        id: String,
        device: Device,
        site: Site,
        buddies: [Buddy],
        equipment: [Equipment],
        startTime: Date
    ) throws {
        let durationMin = 90
        let maxDepth: Float = 32.0
        let avgDepth: Float = 24.0

        let dive = Dive(
            id: id,
            deviceId: device.id,
            startTimeUnix: Int64(startTime.timeIntervalSince1970),
            endTimeUnix: Int64(startTime.timeIntervalSince1970) + Int64(durationMin * 60),
            maxDepthM: maxDepth,
            avgDepthM: avgDepth,
            bottomTimeSec: Int32(durationMin * 60),
            isCcr: true,
            decoRequired: false,
            cnsPercent: 18.0,
            otu: 32.0,
            siteId: site.id
        )

        try diveService.saveDive(
            dive,
            tags: ["cave", "ccr", "training"],
            buddyIds: buddies.map(\.id),
            equipmentIds: equipment.map(\.id)
        )

        // Generate samples for CCR cave dive profile
        let samples = generateCaveDiveProfile(diveId: id, durationMin: durationMin, maxDepth: maxDepth, isCCR: true)
        try diveService.saveSamples(samples)
    }

    private func createRecreationalDive(
        id: String,
        device: Device,
        site: Site,
        buddies: [Buddy],
        equipment: [Equipment],
        startTime: Date
    ) throws {
        let durationMin = 52
        let maxDepth: Float = 18.0
        let avgDepth: Float = 12.0

        let dive = Dive(
            id: id,
            deviceId: device.id,
            startTimeUnix: Int64(startTime.timeIntervalSince1970),
            endTimeUnix: Int64(startTime.timeIntervalSince1970) + Int64(durationMin * 60),
            maxDepthM: maxDepth,
            avgDepthM: avgDepth,
            bottomTimeSec: Int32(durationMin * 60),
            isCcr: false,
            decoRequired: false,
            cnsPercent: 8.0,
            otu: 12.0,
            siteId: site.id
        )

        try diveService.saveDive(
            dive,
            tags: ["reef", "photography"],
            buddyIds: buddies.map(\.id),
            equipmentIds: equipment.map(\.id)
        )

        let samples = generateReefDiveProfile(diveId: id, durationMin: durationMin, maxDepth: maxDepth)
        try diveService.saveSamples(samples)
    }

    private func createTechDecoDive(
        id: String,
        device: Device,
        site: Site,
        buddies: [Buddy],
        equipment: [Equipment],
        startTime: Date
    ) throws {
        let durationMin = 180  // 3 hour dive including deco
        let maxDepth: Float = 73.0
        let avgDepth: Float = 35.0

        let dive = Dive(
            id: id,
            deviceId: device.id,
            startTimeUnix: Int64(startTime.timeIntervalSince1970),
            endTimeUnix: Int64(startTime.timeIntervalSince1970) + Int64(durationMin * 60),
            maxDepthM: maxDepth,
            avgDepthM: avgDepth,
            bottomTimeSec: 25 * 60,  // 25 min bottom time
            isCcr: false,
            decoRequired: true,
            cnsPercent: 65.0,
            otu: 85.0,
            siteId: site.id
        )

        try diveService.saveDive(
            dive,
            tags: ["wreck", "technical", "trimix", "deep"],
            buddyIds: buddies.map(\.id),
            equipmentIds: equipment.map(\.id)
        )

        let samples = generateDecoDiveProfile(diveId: id, durationMin: durationMin, maxDepth: maxDepth, bottomTimeMin: 25)
        try diveService.saveSamples(samples)
    }

    private func createNightDive(
        id: String,
        device: Device,
        site: Site,
        buddies: [Buddy],
        equipment: [Equipment],
        startTime: Date
    ) throws {
        let durationMin = 65
        let maxDepth: Float = 8.0
        let avgDepth: Float = 5.5

        let dive = Dive(
            id: id,
            deviceId: device.id,
            startTimeUnix: Int64(startTime.timeIntervalSince1970),
            endTimeUnix: Int64(startTime.timeIntervalSince1970) + Int64(durationMin * 60),
            maxDepthM: maxDepth,
            avgDepthM: avgDepth,
            bottomTimeSec: Int32(durationMin * 60),
            isCcr: false,
            decoRequired: false,
            cnsPercent: 5.0,
            otu: 8.0,
            siteId: site.id
        )

        try diveService.saveDive(
            dive,
            tags: ["night", "shore", "macro"],
            buddyIds: buddies.map(\.id),
            equipmentIds: equipment.map(\.id)
        )

        let samples = generateShallowDiveProfile(diveId: id, durationMin: durationMin, maxDepth: maxDepth)
        try diveService.saveSamples(samples)
    }

    // MARK: - Profile Generation

    private func generateCaveDiveProfile(diveId: String, durationMin: Int, maxDepth: Float, isCCR: Bool) -> [DiveSample] {
        var samples: [DiveSample] = []
        let intervalSec: Int32 = 10
        let totalSamples = (durationMin * 60) / Int(intervalSec)

        for i in 0..<totalSamples {
            let tSec = Int32(i) * intervalSec
            let progress = Float(i) / Float(totalSamples)

            // Cave dive: gradual descent, flat bottom, gradual ascent
            let depth: Float
            if progress < 0.1 {
                // Descent
                depth = maxDepth * (progress / 0.1)
            } else if progress < 0.85 {
                // Bottom phase with small variations
                let variation = sin(Float(i) * 0.1) * 2.0
                depth = maxDepth - 3.0 + variation
            } else {
                // Ascent
                let ascentProgress = (progress - 0.85) / 0.15
                depth = maxDepth * (1.0 - ascentProgress)
            }

            let temp: Float = 22.0 - (depth / 10.0)  // Thermocline
            let setpoint: Float? = isCCR ? 1.3 : nil

            samples.append(DiveSample(
                diveId: diveId,
                tSec: tSec,
                depthM: max(0, depth),
                tempC: temp,
                setpointPpo2: setpoint,
                ceilingM: nil,
                gf99: nil
            ))
        }

        return samples
    }

    private func generateReefDiveProfile(diveId: String, durationMin: Int, maxDepth: Float) -> [DiveSample] {
        var samples: [DiveSample] = []
        let intervalSec: Int32 = 10
        let totalSamples = (durationMin * 60) / Int(intervalSec)

        for i in 0..<totalSamples {
            let tSec = Int32(i) * intervalSec
            let progress = Float(i) / Float(totalSamples)

            // Reef dive: multilevel profile
            let depth: Float
            if progress < 0.1 {
                depth = maxDepth * (progress / 0.1)
            } else if progress < 0.4 {
                // Deep portion
                depth = maxDepth - Float.random(in: 0...3)
            } else if progress < 0.7 {
                // Mid-level
                depth = maxDepth * 0.6 + Float.random(in: -2...2)
            } else if progress < 0.9 {
                // Shallow portion
                depth = maxDepth * 0.3 + Float.random(in: -1...1)
            } else {
                // Ascent and safety stop
                let ascentProgress = (progress - 0.9) / 0.1
                if ascentProgress < 0.5 {
                    depth = 5.0  // Safety stop
                } else {
                    depth = 5.0 * (1.0 - (ascentProgress - 0.5) * 2)
                }
            }

            let temp: Float = 26.0 - (depth / 15.0)

            samples.append(DiveSample(
                diveId: diveId,
                tSec: tSec,
                depthM: max(0, depth),
                tempC: temp,
                setpointPpo2: nil,
                ceilingM: nil,
                gf99: nil
            ))
        }

        return samples
    }

    private func generateDecoDiveProfile(diveId: String, durationMin: Int, maxDepth: Float, bottomTimeMin: Int) -> [DiveSample] {
        var samples: [DiveSample] = []
        let intervalSec: Int32 = 10
        let totalSamples = (durationMin * 60) / Int(intervalSec)
        let bottomSamples = (bottomTimeMin * 60) / Int(intervalSec)

        // Deco stops (simplified)
        let decoStops: [(depth: Float, durationMin: Int)] = [
            (21, 3), (18, 5), (15, 7), (12, 10), (9, 15), (6, 30), (3, 15)
        ]

        for i in 0..<totalSamples {
            let tSec = Int32(i) * intervalSec

            let depth: Float
            let ceiling: Float?
            let gf99: Float?

            if i < 20 {
                // Descent (fast, ~3 min)
                depth = maxDepth * Float(i) / 20.0
                ceiling = nil
                gf99 = nil
            } else if i < bottomSamples + 20 {
                // Bottom time
                depth = maxDepth + Float.random(in: -2...2)
                ceiling = 21.0  // Building deco obligation
                gf99 = 40.0 + Float(i - 20) * 0.5
            } else {
                // Ascent and deco
                let decoProgress = i - bottomSamples - 20
                var remainingSamples = decoProgress
                var currentDepth: Float = maxDepth
                var currentCeiling: Float? = 21.0

                // Ascent to first stop
                if remainingSamples < 50 {
                    currentDepth = maxDepth - Float(remainingSamples) * (maxDepth - 21.0) / 50.0
                } else {
                    remainingSamples -= 50
                    // Work through deco stops
                    for stop in decoStops {
                        let stopSamples = (stop.durationMin * 60) / Int(intervalSec)
                        if remainingSamples < stopSamples {
                            currentDepth = stop.depth
                            currentCeiling = stop.depth > 3 ? stop.depth - 3 : nil
                            break
                        }
                        remainingSamples -= stopSamples
                        currentDepth = stop.depth
                    }
                }

                depth = max(0, currentDepth)
                ceiling = currentCeiling
                gf99 = depth > 0 ? min(99, 70 + Float.random(in: 0...20)) : nil
            }

            let temp: Float = depth > 30 ? 8.0 : (18.0 - depth / 5.0)

            samples.append(DiveSample(
                diveId: diveId,
                tSec: tSec,
                depthM: max(0, depth),
                tempC: temp,
                setpointPpo2: nil,
                ceilingM: ceiling,
                gf99: gf99
            ))
        }

        return samples
    }

    private func generateShallowDiveProfile(diveId: String, durationMin: Int, maxDepth: Float) -> [DiveSample] {
        var samples: [DiveSample] = []
        let intervalSec: Int32 = 10
        let totalSamples = (durationMin * 60) / Int(intervalSec)

        for i in 0..<totalSamples {
            let tSec = Int32(i) * intervalSec
            let progress = Float(i) / Float(totalSamples)

            // Shallow night dive: mostly flat with exploration variations
            let depth: Float
            if progress < 0.05 {
                depth = maxDepth * (progress / 0.05)
            } else if progress < 0.95 {
                // Wandering around shallow reef
                let variation = sin(Float(i) * 0.05) * 2.0 + cos(Float(i) * 0.03) * 1.5
                depth = maxDepth * 0.7 + variation
            } else {
                let ascentProgress = (progress - 0.95) / 0.05
                depth = (maxDepth * 0.7) * (1.0 - ascentProgress)
            }

            let temp: Float = 24.0  // Warm shallow water

            samples.append(DiveSample(
                diveId: diveId,
                tSec: tSec,
                depthM: max(0, depth),
                tempC: temp,
                setpointPpo2: nil,
                ceilingM: nil,
                gf99: nil
            ))
        }

        return samples
    }
}
