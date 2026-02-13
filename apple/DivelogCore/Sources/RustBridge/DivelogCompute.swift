import Foundation

// Re-export the UniFFI-generated types for use throughout the codebase
// The actual implementations come from the generated divelog_compute.swift file

// MARK: - DivelogCompute Namespace

/// Swift interface to the Rust compute core.
/// This provides a namespace for the compute functions and re-exports types.
public enum DivelogCompute {
    /// Validate a formula expression.
    /// - Returns: nil if valid, or an error message if invalid.
    public static func validateFormula(_ expression: String) -> String? {
        // Call the UniFFI-generated free function (use module prefix to disambiguate)
        DivelogCore.validateFormula(expression: expression)
    }

    /// Validate a formula with available variables check.
    /// - Returns: nil if valid, or an error message if invalid.
    public static func validateFormulaWithVariables(_ expression: String, available: [String]) -> String? {
        // Call the UniFFI-generated free function
        DivelogCore.validateFormulaWithVariables(expression: expression, available: available)
    }

    /// Evaluate a formula expression with the given variables.
    public static func evaluateFormula(_ expression: String, variables: [String: Double]) throws -> Double {
        // Call the UniFFI-generated free function
        try DivelogCore.evaluateFormula(expression: expression, variables: variables)
    }

    /// Compute statistics for a dive from samples.
    public static func computeDiveStats(dive: DiveInput, samples: [SampleInput]) -> DiveStats {
        // Call the UniFFI-generated free function
        DivelogCore.computeDiveStats(dive: dive, samples: samples)
    }

    /// Compute statistics for a segment from samples.
    public static func computeSegmentStats(startTSec: Int32, endTSec: Int32, samples: [SampleInput]) -> SegmentStats {
        // Call the UniFFI-generated free function
        DivelogCore.computeSegmentStats(startTSec: startTSec, endTSec: endTSec, samples: samples)
    }

    /// Get list of supported formula functions.
    public static func supportedFunctions() -> [FunctionInfo] {
        // Call the UniFFI-generated free function
        DivelogCore.supportedFunctions()
    }

    /// Compute Surface Gradient Factor via Bühlmann ZHL-16C tissue simulation.
    public static func computeSurfaceGf(
        samples: [SampleInput],
        gasMixes: [GasMixInput],
        surfacePressureBar: Double? = nil
    ) -> [SurfaceGfPoint] {
        DivelogCore.computeSurfaceGf(
            samples: samples,
            gasMixes: gasMixes,
            surfacePressureBar: surfacePressureBar
        )
    }
}

// Note: DiveInput, SampleInput, DiveStats, SegmentStats, FunctionInfo, DepthClass, and FormulaError
// are all defined in the generated divelog_compute.swift file and are automatically available.
