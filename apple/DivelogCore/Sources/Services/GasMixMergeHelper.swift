import GRDB

/// Key for deduplicating gas mixes by composition and usage.
struct GasMixKey: Hashable {
    let o2: Int   // o2Fraction * 1000 as integer for reliable hashing
    let he: Int   // heFraction * 1000 as integer for reliable hashing
    let usage: String?
}

/// Shared gas mix merge and sample index remapping for BLE and Cloud import paths.
enum GasMixMergeHelper {
    /// Returns only gas mixes whose index appears on at least one sample.
    static func filterUsedGasMixes(_ mixes: [ParsedGasMix], samples: [ParsedSample]) -> [ParsedGasMix] {
        let usedIndices = Set(samples.compactMap(\.gasmixIndex))
        guard !usedIndices.isEmpty else { return mixes }
        return mixes.filter { usedIndices.contains($0.index) }
    }

    /// Merges incoming gas mixes into existing dive mixes and inserts new rows.
    /// Returns a map from source mix index to persisted `mix_index`.
    static func mergeGasMixes(
        existingMixes: [GasMix],
        incomingMixes: [ParsedGasMix],
        diveId: String,
        deviceId: String,
        db: Database
    ) throws -> [Int: Int] {
        var mixByKey: [GasMixKey: Int] = Dictionary(
            existingMixes.map {
                (GasMixKey(o2: Int($0.o2Fraction * 1000), he: Int($0.heFraction * 1000), usage: $0.usage),
                 $0.mixIndex)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var nextMixIndex = (existingMixes.map(\.mixIndex).max() ?? -1) + 1

        var indexRemap: [Int: Int] = [:]
        for mix in incomingMixes {
            let key = GasMixKey(
                o2: Int(mix.o2Fraction * 1000),
                he: Int(mix.heFraction * 1000),
                usage: mix.usage
            )
            if let existingIdx = mixByKey[key] {
                indexRemap[mix.index] = existingIdx
            } else {
                indexRemap[mix.index] = nextMixIndex
                mixByKey[key] = nextMixIndex
                try GasMix(
                    diveId: diveId,
                    mixIndex: nextMixIndex,
                    o2Fraction: mix.o2Fraction,
                    heFraction: mix.heFraction,
                    usage: mix.usage,
                    deviceId: deviceId
                ).insert(db)
                nextMixIndex += 1
            }
        }
        return indexRemap
    }

    /// Inserts parsed samples with remapped `gasmixIndex` values.
    static func insertSamples(
        samples: [ParsedSample],
        diveId: String,
        deviceId: String,
        indexRemap: [Int: Int],
        db: Database
    ) throws {
        for sample in samples {
            try DiveSample(
                diveId: diveId,
                deviceId: deviceId,
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
                gasmixIndex: sample.gasmixIndex.flatMap { indexRemap[$0] },
                atPlusFiveTtsMin: sample.atPlusFiveTtsMin
            ).insert(db)
        }
    }
}
