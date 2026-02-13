import Foundation
import GRDB

/// Service for formula validation, evaluation, and computed stats.
public final class FormulaService: Sendable {
    private let database: DivelogDatabase

    public init(database: DivelogDatabase) {
        self.database = database
    }

    // MARK: - Formula Validation

    /// Validate a formula expression.
    /// - Returns: nil if valid, or an error message if invalid.
    public func validateFormula(_ expression: String) -> String? {
        DivelogCompute.validateFormula(expression)
    }

    /// Validate a formula for dive context.
    public func validateFormulaForDive(_ expression: String) -> String? {
        DivelogCompute.validateFormulaWithVariables(expression, available: FormulaVariables.diveVariables)
    }

    /// Validate a formula for segment context.
    public func validateFormulaForSegment(_ expression: String) -> String? {
        DivelogCompute.validateFormulaWithVariables(expression, available: FormulaVariables.segmentVariables)
    }

    // MARK: - Formula Evaluation

    /// Evaluate a formula for a specific dive.
    public func evaluateFormulaForDive(_ expression: String, diveId: String) throws -> Double {
        let (dive, samples) = try database.dbQueue.read { db in
            guard let dive = try Dive.fetchOne(db, key: diveId) else {
                throw FormulaServiceError.diveNotFound(diveId)
            }
            let samples = try DiveSample
                .filter(Column("dive_id") == diveId)
                .order(Column("t_sec"))
                .fetchAll(db)
            return (dive, samples)
        }

        let stats = computeDiveStats(dive: dive, samples: samples)
        let variables = FormulaVariables.fromDive(dive, stats: stats)

        return try DivelogCompute.evaluateFormula(expression, variables: variables)
    }

    /// Evaluate a formula for a dive using pre-fetched stats (avoids redundant sample load).
    public func evaluateFormulaForDive(_ expression: String, dive: Dive, stats: DiveStats) throws -> Double {
        let variables = FormulaVariables.fromDive(dive, stats: stats)
        return try DivelogCompute.evaluateFormula(expression, variables: variables)
    }

    /// Evaluate a formula for a specific segment.
    public func evaluateFormulaForSegment(_ expression: String, segmentId: String) throws -> Double {
        let (segment, samples) = try database.dbQueue.read { db in
            guard let segment = try Segment.fetchOne(db, key: segmentId) else {
                throw FormulaServiceError.segmentNotFound(segmentId)
            }
            let samples = try DiveSample
                .filter(Column("dive_id") == segment.diveId)
                .order(Column("t_sec"))
                .fetchAll(db)
            return (segment, samples)
        }

        let stats = computeSegmentStats(segment: segment, samples: samples)
        let variables = FormulaVariables.fromSegment(segment, stats: stats)

        return try DivelogCompute.evaluateFormula(expression, variables: variables)
    }

    // MARK: - Stats Computation

    /// Compute statistics for a dive.
    public func computeDiveStats(diveId: String) throws -> DiveStats {
        let (dive, samples) = try database.dbQueue.read { db in
            guard let dive = try Dive.fetchOne(db, key: diveId) else {
                throw FormulaServiceError.diveNotFound(diveId)
            }
            let samples = try DiveSample
                .filter(Column("dive_id") == diveId)
                .order(Column("t_sec"))
                .fetchAll(db)
            return (dive, samples)
        }

        return computeDiveStats(dive: dive, samples: samples)
    }

    /// Compute statistics for a segment.
    public func computeSegmentStats(segmentId: String) throws -> SegmentStats {
        let (segment, samples) = try database.dbQueue.read { db in
            guard let segment = try Segment.fetchOne(db, key: segmentId) else {
                throw FormulaServiceError.segmentNotFound(segmentId)
            }
            let samples = try DiveSample
                .filter(Column("dive_id") == segment.diveId)
                .order(Column("t_sec"))
                .fetchAll(db)
            return (segment, samples)
        }

        return computeSegmentStats(segment: segment, samples: samples)
    }

    // MARK: - Calculated Fields

    /// Compute and store a calculated field for a dive.
    public func computeAndStoreCalculatedField(formulaId: String, diveId: String) throws -> Double {
        let formula = try database.dbQueue.read { db in
            guard let formula = try Formula.fetchOne(db, key: formulaId) else {
                throw FormulaServiceError.formulaNotFound(formulaId)
            }
            return formula
        }

        let value = try evaluateFormulaForDive(formula.expression, diveId: diveId)

        let field = CalculatedField(formulaId: formulaId, diveId: diveId, value: value)
        try database.dbQueue.write { db in
            try field.save(db)
        }

        return value
    }

    // MARK: - Private Helpers

    private func computeDiveStats(dive: Dive, samples: [DiveSample]) -> DiveStats {
        let diveInput = DiveInput(
            startTimeUnix: dive.startTimeUnix,
            endTimeUnix: dive.endTimeUnix,
            bottomTimeSec: dive.bottomTimeSec
        )

        let sampleInputs = samples.map { sample in
            SampleInput(
                tSec: sample.tSec,
                depthM: sample.depthM,
                tempC: sample.tempC,
                setpointPpo2: sample.setpointPpo2,
                ceilingM: sample.ceilingM,
                gf99: sample.gf99,
                gasmixIndex: sample.gasmixIndex.map { Int32($0) },
                ppo2: sample.ppo2_1 ?? sample.setpointPpo2
            )
        }

        return DivelogCompute.computeDiveStats(dive: diveInput, samples: sampleInputs)
    }

    private func computeSegmentStats(segment: Segment, samples: [DiveSample]) -> SegmentStats {
        let sampleInputs = samples.map { sample in
            SampleInput(
                tSec: sample.tSec,
                depthM: sample.depthM,
                tempC: sample.tempC,
                setpointPpo2: sample.setpointPpo2,
                ceilingM: sample.ceilingM,
                gf99: sample.gf99,
                gasmixIndex: sample.gasmixIndex.map { Int32($0) },
                ppo2: sample.ppo2_1 ?? sample.setpointPpo2
            )
        }

        return DivelogCompute.computeSegmentStats(
            startTSec: segment.startTSec,
            endTSec: segment.endTSec,
            samples: sampleInputs
        )
    }
}

// MARK: - Errors

public enum FormulaServiceError: Error, Sendable {
    case diveNotFound(String)
    case segmentNotFound(String)
    case formulaNotFound(String)
}

// MARK: - Formula Variables

/// Helper for building variable dictionaries from Swift models.
public enum FormulaVariables {
    /// Available variables for dive formulas.
    public static let diveVariables: [String] = [
        "max_depth_m",
        "avg_depth_m",
        "weighted_avg_depth_m",
        "max_depth_ft",
        "avg_depth_ft",
        "weighted_avg_depth_ft",
        "bottom_time_sec",
        "bottom_time_min",
        "cns_percent",
        "otu",
        "is_ccr",
        "deco_required",
        "o2_consumed_psi",
        "o2_consumed_bar",
        "o2_rate_cuft_min",
        "o2_rate_l_min",
        "total_time_sec",
        "total_time_min",
        "deco_time_sec",
        "deco_time_min",
        "min_temp_c",
        "max_temp_c",
        "avg_temp_c",
        "min_temp_f",
        "max_temp_f",
        "avg_temp_f",
        "gas_switch_count",
        "max_ceiling_m",
        "max_ceiling_ft",
        "max_gf99",
        "descent_rate_m_min",
        "ascent_rate_m_min",
    ]

    /// Available variables for segment formulas.
    public static let segmentVariables: [String] = [
        "start_t_sec",
        "end_t_sec",
        "duration_sec",
        "duration_min",
        "max_depth_m",
        "avg_depth_m",
        "max_depth_ft",
        "avg_depth_ft",
        "min_temp_c",
        "max_temp_c",
        "min_temp_f",
        "max_temp_f",
        "deco_time_sec",
        "deco_time_min",
        "sample_count",
    ]

    /// Build variable dictionary from a dive and its stats.
    public static func fromDive(_ dive: Dive, stats: DiveStats) -> [String: Double] {
        var vars: [String: Double] = [:]

        // Basic dive properties
        vars["max_depth_m"] = Double(dive.maxDepthM)
        vars["avg_depth_m"] = Double(dive.avgDepthM)
        vars["bottom_time_sec"] = Double(dive.bottomTimeSec)
        vars["bottom_time_min"] = Double(dive.bottomTimeSec) / 60.0
        vars["cns_percent"] = Double(dive.cnsPercent)
        vars["otu"] = Double(dive.otu)
        vars["is_ccr"] = dive.isCcr ? 1.0 : 0.0
        vars["deco_required"] = dive.decoRequired ? 1.0 : 0.0

        // O2 consumption (use 0 if not available)
        vars["o2_consumed_psi"] = Double(dive.o2ConsumedPsi ?? 0)
        vars["o2_consumed_bar"] = Double(dive.o2ConsumedBar ?? 0)
        vars["o2_rate_cuft_min"] = Double(dive.o2RateCuftMin ?? 0)
        vars["o2_rate_l_min"] = Double(dive.o2RateLMin ?? 0)

        // Computed stats
        vars["total_time_sec"] = Double(stats.totalTimeSec)
        vars["total_time_min"] = Double(stats.totalTimeSec) / 60.0
        vars["deco_time_sec"] = Double(stats.decoTimeSec)
        vars["deco_time_min"] = Double(stats.decoTimeSec) / 60.0
        vars["weighted_avg_depth_m"] = Double(stats.weightedAvgDepthM)
        vars["min_temp_c"] = Double(stats.minTempC)
        vars["max_temp_c"] = Double(stats.maxTempC)
        vars["avg_temp_c"] = Double(stats.avgTempC)
        vars["gas_switch_count"] = Double(stats.gasSwitchCount)
        vars["max_ceiling_m"] = Double(stats.maxCeilingM)
        vars["max_gf99"] = Double(stats.maxGf99)
        vars["descent_rate_m_min"] = Double(stats.descentRateMMin)
        vars["ascent_rate_m_min"] = Double(stats.ascentRateMMin)

        UnitFormatter.addImperialVariables(to: &vars)

        return vars
    }

    /// Build variable dictionary from a segment and its stats.
    public static func fromSegment(_ segment: Segment, stats: SegmentStats) -> [String: Double] {
        var vars: [String: Double] = [:]

        // Segment properties
        vars["start_t_sec"] = Double(segment.startTSec)
        vars["end_t_sec"] = Double(segment.endTSec)

        // Computed stats
        vars["duration_sec"] = Double(stats.durationSec)
        vars["duration_min"] = Double(stats.durationSec) / 60.0
        vars["max_depth_m"] = Double(stats.maxDepthM)
        vars["avg_depth_m"] = Double(stats.avgDepthM)
        vars["min_temp_c"] = Double(stats.minTempC)
        vars["max_temp_c"] = Double(stats.maxTempC)
        vars["deco_time_sec"] = Double(stats.decoTimeSec)
        vars["deco_time_min"] = Double(stats.decoTimeSec) / 60.0
        vars["sample_count"] = Double(stats.sampleCount)

        UnitFormatter.addImperialVariables(to: &vars)

        return vars
    }
}
