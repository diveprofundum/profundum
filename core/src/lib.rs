//! Divelog Compute Core
//!
//! A minimal, stateless compute library for dive log applications.
//! Provides formula parsing/evaluation and metrics computation.
//!
//! This crate is designed to be used via FFI (UniFFI) from Swift/Kotlin.
//! All functions are pure - no database, no storage, no side effects.

// Allow clippy lint that triggers on generated UniFFI code
#![allow(clippy::empty_line_after_doc_comments)]

pub mod buhlmann;
pub mod error;
pub mod formula;
pub mod metrics;

use std::collections::HashMap;

uniffi::include_scaffolding!("divelog_compute");

// Re-export public types for Rust consumers
pub use buhlmann::{GasMixInput, SurfaceGfPoint};
pub use error::FormulaError;
pub use formula::{compute, validate, validate_with_variables, FunctionInfo};
pub use metrics::{DepthClass, DiveInput, DiveStats, SampleInput, SegmentStats};

// ============================================================================
// FFI Functions (called from Swift/Kotlin via UniFFI)
// ============================================================================

/// Validate a formula expression. Returns None if valid, or error message if invalid.
fn validate_formula(expression: &str) -> Option<String> {
    match formula::validate(expression) {
        Ok(()) => None,
        Err(e) => Some(e.to_string()),
    }
}

/// Validate a formula with available variables check.
/// Returns None if valid, or error message if invalid.
fn validate_formula_with_variables(expression: &str, available: Vec<String>) -> Option<String> {
    let available_refs: Vec<&str> = available.iter().map(|s| s.as_str()).collect();
    match formula::validate_with_variables(expression, &available_refs) {
        Ok(()) => None,
        Err(e) => Some(e.to_string()),
    }
}

/// Evaluate a formula expression with the given variables.
fn evaluate_formula(
    expression: &str,
    variables: HashMap<String, f64>,
) -> Result<f64, FormulaError> {
    let var_provider = |name: &str| variables.get(name).copied();
    formula::compute(expression, &var_provider)
}

/// Compute statistics for a dive from samples.
fn compute_dive_stats(dive: DiveInput, samples: Vec<SampleInput>) -> DiveStats {
    DiveStats::compute(&dive, &samples)
}

/// Compute statistics for a segment from samples.
fn compute_segment_stats(
    start_t_sec: i32,
    end_t_sec: i32,
    samples: Vec<SampleInput>,
) -> SegmentStats {
    SegmentStats::compute(start_t_sec, end_t_sec, &samples)
}

/// Get list of supported functions for UI display.
fn supported_functions() -> Vec<FunctionInfo> {
    formula::supported_functions()
}

/// Compute Surface Gradient Factor via Bühlmann ZHL-16C tissue simulation.
fn compute_surface_gf(
    samples: Vec<SampleInput>,
    gas_mixes: Vec<GasMixInput>,
    surface_pressure_bar: Option<f64>,
) -> Vec<SurfaceGfPoint> {
    buhlmann::compute_surface_gf(&samples, &gas_mixes, surface_pressure_bar)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_formula_valid() {
        assert!(validate_formula("1 + 2").is_none());
        assert!(validate_formula("max(x, y)").is_none());
    }

    #[test]
    fn test_validate_formula_invalid() {
        assert!(validate_formula("").is_some());
        assert!(validate_formula("1 +").is_some());
    }

    #[test]
    fn test_validate_with_variables() {
        let vars = vec!["x".to_string(), "y".to_string()];
        assert!(validate_formula_with_variables("x + y", vars.clone()).is_none());
        assert!(validate_formula_with_variables("x + z", vars).is_some());
    }

    #[test]
    fn test_evaluate_formula() {
        let mut vars = HashMap::new();
        vars.insert("x".to_string(), 10.0);
        vars.insert("y".to_string(), 5.0);

        let result = evaluate_formula("x + y", vars.clone()).unwrap();
        assert!((result - 15.0).abs() < f64::EPSILON);

        let result = evaluate_formula("x / y", vars).unwrap();
        assert!((result - 2.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_compute_dive_stats() {
        let dive = DiveInput {
            start_time_unix: 1700000000,
            end_time_unix: 1700003600,
            bottom_time_sec: 3000,
        };

        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
                temp_c: 22.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
            },
            SampleInput {
                t_sec: 300,
                depth_m: 30.0,
                temp_c: 16.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: Some(60.0),
                gasmix_index: None,
                ppo2: None,
            },
            SampleInput {
                t_sec: 600,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
            },
        ];

        let stats = compute_dive_stats(dive, samples);
        assert_eq!(stats.max_depth_m, 30.0);
        assert_eq!(stats.depth_class, DepthClass::Deep);
    }

    #[test]
    fn test_compute_segment_stats() {
        let samples = vec![
            SampleInput {
                t_sec: 100,
                depth_m: 10.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
            },
            SampleInput {
                t_sec: 200,
                depth_m: 25.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
            },
            SampleInput {
                t_sec: 300,
                depth_m: 20.0,
                temp_c: 19.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
            },
        ];

        let stats = compute_segment_stats(100, 300, samples);
        assert_eq!(stats.duration_sec, 200);
        assert_eq!(stats.max_depth_m, 25.0);
        assert_eq!(stats.sample_count, 3);
    }

    #[test]
    fn test_supported_functions() {
        let funcs = supported_functions();
        assert!(!funcs.is_empty());

        let names: Vec<_> = funcs.iter().map(|f| f.name.as_str()).collect();
        assert!(names.contains(&"min"));
        assert!(names.contains(&"max"));
        assert!(names.contains(&"round"));
        assert!(names.contains(&"abs"));
    }
}
