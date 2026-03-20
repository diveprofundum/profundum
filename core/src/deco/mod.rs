//! Decompression simulation engine.
//!
//! Supports multiple deco models via the internal `DecoEngine` trait,
//! dispatched by `DecoModel` enum at the FFI boundary.

pub mod shared;
pub mod types;

mod buhlmann_engine;
mod thalmann_engine;

pub use types::*;

use buhlmann_engine::BuhlmannEngine;
use thalmann_engine::ThalmannEngine;

/// Run a deco simulation with the specified model and parameters.
///
/// This is the main entry point for the deco engine, exposed via FFI.
pub fn compute_deco_simulation(params: DecoSimParams) -> Result<DecoSimResult, DecoSimError> {
    match params.model {
        DecoModel::BuhlmannZhl16c => BuhlmannEngine.simulate(&params),
        DecoModel::ThalmannElDca => ThalmannEngine.simulate(&params),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metrics::SampleInput;

    fn sample(t_sec: i32, depth_m: f32) -> SampleInput {
        SampleInput {
            t_sec,
            depth_m,
            temp_c: 20.0,
            setpoint_ppo2: None,
            ceiling_m: None,
            gf99: None,
            gasmix_index: None,
            ppo2: None,
            tts_sec: None,
            ndl_sec: None,
            deco_stop_depth_m: None,
            at_plus_five_tts_min: None,
        }
    }

    #[test]
    fn test_thalmann_returns_unsupported() {
        let params = DecoSimParams {
            model: DecoModel::ThalmannElDca,
            samples: vec![sample(0, 0.0)],
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: None,
            last_stop_depth_m: None,
            stop_interval_m: None,
            gf_low: None,
            gf_high: None,
            plan_ascent: false,
        };

        let result = compute_deco_simulation(params);
        assert!(matches!(result, Err(DecoSimError::UnsupportedModel { .. })));
    }

    #[test]
    fn test_dispatch_buhlmann() {
        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples: vec![sample(0, 0.0), sample(600, 20.0)],
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: None,
            last_stop_depth_m: None,
            stop_interval_m: None,
            gf_low: None,
            gf_high: None,
            plan_ascent: false,
        };

        let result = compute_deco_simulation(params).unwrap();
        assert_eq!(result.points.len(), 2);
        assert_eq!(result.model, DecoModel::BuhlmannZhl16c);
    }

    #[test]
    fn test_empty_samples_via_dispatch() {
        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples: vec![],
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: None,
            last_stop_depth_m: None,
            stop_interval_m: None,
            gf_low: None,
            gf_high: None,
            plan_ascent: false,
        };

        let result = compute_deco_simulation(params);
        assert!(matches!(result, Err(DecoSimError::EmptySamples { .. })));
    }
}
