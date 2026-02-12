import Foundation

/// Intermediate gas mix parsed from a dive computer.
public struct ParsedGasMix: Sendable {
    public var index: Int
    public var o2Fraction: Float
    public var heFraction: Float
    public var usage: String?

    public init(index: Int, o2Fraction: Float, heFraction: Float, usage: String? = nil) {
        self.index = index
        self.o2Fraction = o2Fraction
        self.heFraction = heFraction
        self.usage = usage
    }
}

/// Intermediate tank info parsed from a dive computer.
public struct ParsedTank: Sendable {
    public var gasmixIndex: Int
    public var volumeL: Float?
    public var beginPressureBar: Float?
    public var endPressureBar: Float?
    public var usage: String?

    public init(gasmixIndex: Int, volumeL: Float? = nil, beginPressureBar: Float? = nil,
                endPressureBar: Float? = nil, usage: String? = nil) {
        self.gasmixIndex = gasmixIndex
        self.volumeL = volumeL
        self.beginPressureBar = beginPressureBar
        self.endPressureBar = endPressureBar
        self.usage = usage
    }
}

/// Intermediate representation of a dive parsed from a dive computer.
public struct ParsedDive: Sendable {
    public var startTimeUnix: Int64
    public var endTimeUnix: Int64
    public var maxDepthM: Float
    public var avgDepthM: Float
    public var bottomTimeSec: Int32
    public var isCcr: Bool
    public var decoRequired: Bool
    public var cnsPercent: Float
    public var otu: Float
    public var computerDiveNumber: Int?
    public var fingerprint: Data?
    public var samples: [ParsedSample]
    public var minTempC: Float?
    public var maxTempC: Float?
    public var avgTempC: Float?
    public var gfLow: Int?
    public var gfHigh: Int?
    public var decoModel: String?
    public var salinity: String?
    public var surfacePressureBar: Float?
    public var lat: Double?
    public var lon: Double?
    public var gasMixes: [ParsedGasMix]
    public var tanks: [ParsedTank]

    public init(
        startTimeUnix: Int64,
        endTimeUnix: Int64,
        maxDepthM: Float,
        avgDepthM: Float,
        bottomTimeSec: Int32,
        isCcr: Bool = false,
        decoRequired: Bool = false,
        cnsPercent: Float = 0,
        otu: Float = 0,
        computerDiveNumber: Int? = nil,
        fingerprint: Data? = nil,
        samples: [ParsedSample] = [],
        minTempC: Float? = nil,
        maxTempC: Float? = nil,
        avgTempC: Float? = nil,
        gfLow: Int? = nil,
        gfHigh: Int? = nil,
        decoModel: String? = nil,
        salinity: String? = nil,
        surfacePressureBar: Float? = nil,
        lat: Double? = nil,
        lon: Double? = nil,
        gasMixes: [ParsedGasMix] = [],
        tanks: [ParsedTank] = []
    ) {
        self.startTimeUnix = startTimeUnix
        self.endTimeUnix = endTimeUnix
        self.maxDepthM = maxDepthM
        self.avgDepthM = avgDepthM
        self.bottomTimeSec = bottomTimeSec
        self.isCcr = isCcr
        self.decoRequired = decoRequired
        self.cnsPercent = cnsPercent
        self.otu = otu
        self.computerDiveNumber = computerDiveNumber
        self.fingerprint = fingerprint
        self.samples = samples
        self.minTempC = minTempC
        self.maxTempC = maxTempC
        self.avgTempC = avgTempC
        self.gfLow = gfLow
        self.gfHigh = gfHigh
        self.decoModel = decoModel
        self.salinity = salinity
        self.surfacePressureBar = surfacePressureBar
        self.lat = lat
        self.lon = lon
        self.gasMixes = gasMixes
        self.tanks = tanks
    }
}

/// Intermediate representation of a sample parsed from a dive computer.
public struct ParsedSample: Sendable {
    public var tSec: Int32
    public var depthM: Float
    public var tempC: Float
    public var setpointPpo2: Float?
    public var ceilingM: Float?
    public var gf99: Float?
    public var ppo2_1: Float?
    public var ppo2_2: Float?
    public var ppo2_3: Float?
    public var cns: Float?
    public var tankPressure1Bar: Float?
    public var tankPressure2Bar: Float?
    public var ttsSec: Int?
    public var ndlSec: Int?
    public var decoStopDepthM: Float?
    public var rbtSec: Int?
    public var gasmixIndex: Int?
    public var atPlusFiveTtsMin: Int?

    public init(
        tSec: Int32,
        depthM: Float,
        tempC: Float,
        setpointPpo2: Float? = nil,
        ceilingM: Float? = nil,
        gf99: Float? = nil,
        ppo2_1: Float? = nil,
        ppo2_2: Float? = nil,
        ppo2_3: Float? = nil,
        cns: Float? = nil,
        tankPressure1Bar: Float? = nil,
        tankPressure2Bar: Float? = nil,
        ttsSec: Int? = nil,
        ndlSec: Int? = nil,
        decoStopDepthM: Float? = nil,
        rbtSec: Int? = nil,
        gasmixIndex: Int? = nil,
        atPlusFiveTtsMin: Int? = nil
    ) {
        self.tSec = tSec
        self.depthM = depthM
        self.tempC = tempC
        self.setpointPpo2 = setpointPpo2
        self.ceilingM = ceilingM
        self.gf99 = gf99
        self.ppo2_1 = ppo2_1
        self.ppo2_2 = ppo2_2
        self.ppo2_3 = ppo2_3
        self.cns = cns
        self.tankPressure1Bar = tankPressure1Bar
        self.tankPressure2Bar = tankPressure2Bar
        self.ttsSec = ttsSec
        self.ndlSec = ndlSec
        self.decoStopDepthM = decoStopDepthM
        self.rbtSec = rbtSec
        self.gasmixIndex = gasmixIndex
        self.atPlusFiveTtsMin = atPlusFiveTtsMin
    }
}

/// Maps parsed dive computer data to domain models.
public enum DiveDataMapper {
    /// Clips post-dive surface timeout padding from samples.
    ///
    /// Shearwater computers stay in dive mode for up to 10 minutes after surfacing.
    /// This finds the last sample where `depthM > surfaceThresholdM` and clips
    /// everything after it, recalculating `endTimeUnix` and `bottomTimeSec`.
    ///
    /// Mid-dive surface intervals are preserved because we find the *last* descent,
    /// not the first surface.
    public static func clipSurfaceTimeout(_ dive: ParsedDive, surfaceThresholdM: Float = 1.0) -> ParsedDive {
        guard !dive.samples.isEmpty else { return dive }

        // Find the last sample at depth
        guard let lastDeepIndex = dive.samples.lastIndex(where: { $0.depthM > surfaceThresholdM }) else {
            return dive
        }

        // If it's already the last sample, no padding to clip
        guard lastDeepIndex < dive.samples.count - 1 else { return dive }

        var clipped = dive
        clipped.samples = Array(dive.samples[0...lastDeepIndex])
        clipped.bottomTimeSec = dive.samples[lastDeepIndex].tSec
        clipped.endTimeUnix = dive.startTimeUnix + Int64(clipped.bottomTimeSec)
        return clipped
    }

    /// Converts a `ParsedDive` into a `Dive`, its `[DiveSample]`, and `[GasMix]`.
    public static func toDive(_ parsed: ParsedDive, deviceId: String) -> (Dive, [DiveSample], [GasMix]) {
        let diveId = UUID().uuidString
        let maxCeiling: Float? = {
            var maxVal: Float = 0
            for s in parsed.samples {
                if let c = s.ceilingM, c > maxVal { maxVal = c }
            }
            return maxVal > 0 ? maxVal : nil
        }()
        let dive = Dive(
            id: diveId,
            deviceId: deviceId,
            startTimeUnix: parsed.startTimeUnix,
            endTimeUnix: parsed.endTimeUnix,
            maxDepthM: parsed.maxDepthM,
            avgDepthM: parsed.avgDepthM,
            bottomTimeSec: parsed.bottomTimeSec,
            isCcr: parsed.isCcr,
            decoRequired: parsed.decoRequired,
            cnsPercent: parsed.cnsPercent,
            otu: parsed.otu,
            computerDiveNumber: parsed.computerDiveNumber,
            fingerprint: parsed.fingerprint,
            minTempC: parsed.minTempC,
            maxTempC: parsed.maxTempC,
            avgTempC: parsed.avgTempC,
            gfLow: parsed.gfLow,
            gfHigh: parsed.gfHigh,
            decoModel: parsed.decoModel,
            salinity: parsed.salinity,
            surfacePressureBar: parsed.surfacePressureBar,
            lat: parsed.lat,
            lon: parsed.lon,
            maxCeilingM: maxCeiling
        )

        let samples = parsed.samples.map { s in
            DiveSample(
                diveId: diveId,
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
                gasmixIndex: s.gasmixIndex,
                atPlusFiveTtsMin: s.atPlusFiveTtsMin
            )
        }

        let gasMixes = parsed.gasMixes.map { m in
            GasMix(
                diveId: diveId,
                mixIndex: m.index,
                o2Fraction: m.o2Fraction,
                heFraction: m.heFraction,
                usage: m.usage
            )
        }

        return (dive, samples, gasMixes)
    }

    // MARK: - PNF Sample Field Extraction

    /// Fields extracted from Shearwater PNF binary that libdivecomputer doesn't parse.
    struct PnfSampleFields: Sendable {
        let gf99: [Float?]
        let atPlusFiveTtsMin: [Int?]
    }

    /// Extracts per-sample GF99 and @+5 TTS values from raw Shearwater PNF binary data.
    /// libdivecomputer doesn't emit these as sample types, but Petrel computers store them
    /// in each 32-byte dive sample record:
    /// - GF99: data byte 24 (raw byte 25 in PNF, 24 in non-PNF)
    /// - @+5 TTS: data byte 26 (raw byte 27 in PNF, 26 in non-PNF), in minutes
    static func extractPnfSampleFields(_ data: Data) -> PnfSampleFields {
        guard data.count >= 32 else { return PnfSampleFields(gf99: [], atPlusFiveTtsMin: []) }

        let sampleSize = 32 // SZ_SAMPLE_PETREL
        // PNF format: first 2 bytes != 0xFFFF
        let isPnf = data.count >= 2 && !(data[0] == 0xFF && data[1] == 0xFF)
        // In PNF, byte 0 of each record is the type; data byte N = raw byte N+1.
        // In non-PNF, no type byte; data byte N = raw byte N.
        let gf99Offset = isPnf ? 25 : 24
        let atPlusFiveOffset = isPnf ? 27 : 26
        let diveSampleType: UInt8 = 0x01

        var gf99Values: [Float?] = []
        var atPlusFiveValues: [Int?] = []
        var offset = 0

        if isPnf {
            while offset + sampleSize <= data.count {
                let recordType = data[offset]
                if recordType == 0xFF { break } // LOG_RECORD_FINAL
                if recordType == diveSampleType {
                    // GF99: 0 = no tissue loading (surface), 0xFF = not computed
                    let rawGf99 = data[offset + gf99Offset]
                    let validGf99 = rawGf99 > 0 && rawGf99 < 0xFF
                    gf99Values.append(validGf99 ? Float(rawGf99) : nil)

                    // @+5 TTS in minutes: 0 = no deco obligation → nil
                    let rawAtPlusFive = data[offset + atPlusFiveOffset]
                    atPlusFiveValues.append(rawAtPlusFive > 0 ? Int(rawAtPlusFive) : nil)
                }
                offset += sampleSize
            }
        } else {
            // Non-PNF: skip 128-byte header and footer, all records are dive samples
            let headerSize = 128
            let footerSize = 128
            guard data.count > headerSize + footerSize else {
                return PnfSampleFields(gf99: [], atPlusFiveTtsMin: [])
            }
            offset = headerSize
            let endOffset = data.count - footerSize
            while offset + sampleSize <= endOffset {
                let rawGf99 = data[offset + gf99Offset]
                let validGf99 = rawGf99 > 0 && rawGf99 < 0xFF
                gf99Values.append(validGf99 ? Float(rawGf99) : nil)

                let rawAtPlusFive = data[offset + atPlusFiveOffset]
                atPlusFiveValues.append(rawAtPlusFive > 0 ? Int(rawAtPlusFive) : nil)

                offset += sampleSize
            }
        }

        return PnfSampleFields(gf99: gf99Values, atPlusFiveTtsMin: atPlusFiveValues)
    }
}
