//! Dive profile generator for replay simulation.
//!
//! Given user-modified parameters (depth, bottom time, gas plan, deco model),
//! produces a synthetic dive profile with computed deco stops using a two-pass
//! approach:
//!
//! 1. **Pass 1**: Generate descent + bottom samples → call deco engine with
//!    `plan_ascent: true` → get deco stop schedule.
//! 2. **Build ascent**: Use the stop schedule to generate ascent + stop samples
//!    with gas switches.
//! 3. **Pass 2**: Run deco engine with `plan_ascent: false` on the complete
//!    profile → get per-point ceiling/GF99/TTS/NDL for charting.

use super::compute_deco_simulation;
use super::types::*;
use crate::buhlmann::GasMixInput;
use crate::deco::shared::{depth_to_pressure, DEFAULT_SURFACE_PRESSURE};
use crate::metrics::SampleInput;

// ============================================================================
// Input / Output Types
// ============================================================================

/// A gas mix with its planned switch depth for the ascent.
#[derive(Debug, Clone)]
pub struct GasSwitchPlan {
    /// The gas mix definition.
    pub gas: GasMixInput,
    /// Depth to switch to this gas during ascent. `None` = bottom/starting gas.
    pub switch_depth_m: Option<f64>,
}

/// Parameters for generating a synthetic dive profile.
#[derive(Debug, Clone)]
pub struct ProfileGenParams {
    /// Target depth in metres.
    pub target_depth_m: f64,
    /// Bottom time in seconds (total time from surface to end of bottom phase, including descent).
    pub bottom_time_sec: i32,
    /// Descent rate in m/min (default 18.0).
    pub descent_rate_m_min: Option<f64>,
    /// Ascent rate in m/min (default 9.0).
    pub ascent_rate_m_min: Option<f64>,
    /// Gas plan: list of gas mixes with switch depths. Empty = air.
    pub gas_plan: Vec<GasSwitchPlan>,
    /// Deco model to use.
    pub model: DecoModel,
    /// Ambient surface pressure in bar (default 1.01325).
    pub surface_pressure_bar: Option<f64>,
    /// Gradient factor low (Bühlmann only, 0–100, default 100).
    pub gf_low: Option<u8>,
    /// Gradient factor high (Bühlmann only, 0–100, default 100).
    pub gf_high: Option<u8>,
    /// Depth of last deco stop in metres (default 3.0).
    pub last_stop_depth_m: Option<f64>,
    /// Deco stop spacing in metres (default 3.0).
    pub stop_interval_m: Option<f64>,
    /// CCR setpoint PPO2 in bar. `None` = open circuit.
    pub setpoint_ppo2: Option<f64>,
    /// Thalmann P_DCS target (Thalmann only, default Pdcs23).
    pub thalmann_pdcs: Option<ThalmannPdcs>,
    /// Sample interval in seconds (default 10).
    pub sample_interval_sec: Option<i32>,
    /// Water temperature in °C (default 20.0).
    pub temp_c: Option<f32>,
}

/// Result of profile generation.
#[derive(Debug, Clone)]
pub struct ProfileGenResult {
    /// Complete dive profile samples (descent + bottom + ascent + stops).
    pub samples: Vec<SampleInput>,
    /// Gas mixes used in the profile.
    pub gas_mixes: Vec<GasMixInput>,
    /// Full deco simulation result (pass 2) with per-point overlay data.
    /// Note: `deco_result.deco_stops` is empty because pass 2 uses `plan_ascent: false`.
    /// The deco stop schedule is baked into the sample profile shape (ascent holds).
    pub deco_result: DecoSimResult,
    /// Time at end of descent phase (seconds).
    pub descent_end_t_sec: i32,
    /// Time at end of bottom phase (seconds).
    pub bottom_end_t_sec: i32,
    /// Total dive time (seconds).
    pub total_time_sec: i32,
    /// True if the pass-1 deco planner hit a safety limit (e.g., max stop time)
    /// and the ascent schedule may be incomplete.
    pub truncated: bool,
}

// ============================================================================
// Constants
// ============================================================================

const DEFAULT_DESCENT_RATE: f64 = 18.0;
const DEFAULT_ASCENT_RATE: f64 = 9.0;
const DEFAULT_SAMPLE_INTERVAL: i32 = 10;
const DEFAULT_TEMP_C: f32 = 20.0;
const DEFAULT_LAST_STOP_DEPTH: f64 = 3.0;
const DEFAULT_STOP_INTERVAL: f64 = 3.0;

// ============================================================================
// Public API
// ============================================================================

/// Generate a synthetic dive profile with computed deco stops.
///
/// Uses a two-pass approach: pass 1 plans the ascent/stops, pass 2 computes
/// the full deco overlay (ceiling, GF99, TTS, NDL) for each sample point.
pub fn generate_dive_profile(params: ProfileGenParams) -> Result<ProfileGenResult, DecoSimError> {
    // ── Validate inputs ─────────────────────────────────────────────────
    validate_params(&params)?;

    // ── Resolve defaults ────────────────────────────────────────────────
    let descent_rate = params.descent_rate_m_min.unwrap_or(DEFAULT_DESCENT_RATE);
    let ascent_rate = params.ascent_rate_m_min.unwrap_or(DEFAULT_ASCENT_RATE);
    let sample_interval = params
        .sample_interval_sec
        .unwrap_or(DEFAULT_SAMPLE_INTERVAL);
    let temp_c = params.temp_c.unwrap_or(DEFAULT_TEMP_C);
    let surface_pressure = params
        .surface_pressure_bar
        .unwrap_or(DEFAULT_SURFACE_PRESSURE);
    let last_stop_depth = params.last_stop_depth_m.unwrap_or(DEFAULT_LAST_STOP_DEPTH);
    let stop_interval = params.stop_interval_m.unwrap_or(DEFAULT_STOP_INTERVAL);

    // ── Build gas mixes ─────────────────────────────────────────────────
    let (gas_mixes, bottom_gas_index, switch_schedule) = build_gas_plan(&params.gas_plan);

    let ctx = SampleCtx {
        setpoint_ppo2: params.setpoint_ppo2,
        surface_pressure,
        temp_c,
        sample_interval,
        ascent_rate,
    };

    // ── Phase 1: Descent + Bottom ───────────────────────────────────────
    let mut samples: Vec<SampleInput> = Vec::new();

    let descent_time_sec = (params.target_depth_m / descent_rate * 60.0).round() as i32;
    let descent_time_sec = descent_time_sec.max(1); // at least 1 second

    // Descent samples
    generate_descent(
        &mut samples,
        params.target_depth_m,
        descent_time_sec,
        bottom_gas_index,
        &ctx,
    );

    let descent_end_t = descent_time_sec;

    // Bottom samples (bottom_time_sec includes descent, so time at depth = total - descent)
    let time_at_depth_sec = (params.bottom_time_sec - descent_time_sec).max(0);
    generate_bottom(
        &mut samples,
        params.target_depth_m,
        descent_end_t,
        time_at_depth_sec,
        bottom_gas_index,
        &ctx,
    );

    let bottom_end_t = descent_end_t + time_at_depth_sec;

    // ── Pass 1: Plan the ascent ─────────────────────────────────────────
    let pass1_params = DecoSimParams {
        model: params.model,
        samples: samples.clone(),
        gas_mixes: gas_mixes.clone(),
        surface_pressure_bar: Some(surface_pressure),
        ascent_rate_m_min: Some(ascent_rate),
        last_stop_depth_m: Some(last_stop_depth),
        stop_interval_m: Some(stop_interval),
        gf_low: params.gf_low,
        gf_high: params.gf_high,
        thalmann_pdcs: params.thalmann_pdcs,
        plan_ascent: true,
    };

    let pass1_result = compute_deco_simulation(pass1_params)?;

    // ── Build ascent samples from deco schedule ─────────────────────────
    generate_ascent(
        &mut samples,
        params.target_depth_m,
        bottom_end_t,
        &pass1_result.deco_stops,
        &switch_schedule,
        bottom_gas_index,
        &ctx,
    );

    let total_time_sec = samples.last().map_or(0, |s| s.t_sec);

    // ── Pass 2: Full deco overlay ───────────────────────────────────────
    let pass2_params = DecoSimParams {
        model: params.model,
        samples: samples.clone(),
        gas_mixes: gas_mixes.clone(),
        surface_pressure_bar: Some(surface_pressure),
        ascent_rate_m_min: Some(ascent_rate),
        last_stop_depth_m: Some(last_stop_depth),
        stop_interval_m: Some(stop_interval),
        gf_low: params.gf_low,
        gf_high: params.gf_high,
        thalmann_pdcs: params.thalmann_pdcs,
        plan_ascent: false,
    };

    let deco_result = compute_deco_simulation(pass2_params)?;

    Ok(ProfileGenResult {
        samples,
        gas_mixes,
        deco_result,
        descent_end_t_sec: descent_end_t,
        bottom_end_t_sec: bottom_end_t,
        total_time_sec,
        truncated: pass1_result.truncated,
    })
}

// ============================================================================
// Validation
// ============================================================================

fn validate_params(params: &ProfileGenParams) -> Result<(), DecoSimError> {
    if params.target_depth_m <= 0.0 {
        return Err(DecoSimError::InvalidParam {
            msg: format!("target_depth_m ({}) must be > 0", params.target_depth_m),
        });
    }
    if params.bottom_time_sec <= 0 {
        return Err(DecoSimError::InvalidParam {
            msg: format!("bottom_time_sec ({}) must be > 0", params.bottom_time_sec),
        });
    }
    if let Some(dr) = params.descent_rate_m_min {
        if dr <= 0.0 {
            return Err(DecoSimError::InvalidParam {
                msg: format!("descent_rate_m_min ({dr}) must be > 0"),
            });
        }
    }
    if let Some(ar) = params.ascent_rate_m_min {
        if ar <= 0.0 {
            return Err(DecoSimError::InvalidParam {
                msg: format!("ascent_rate_m_min ({ar}) must be > 0"),
            });
        }
    }
    if let Some(gf_low) = params.gf_low {
        if gf_low == 0 {
            return Err(DecoSimError::InvalidParam {
                msg: "gf_low must be > 0".to_string(),
            });
        }
    }
    if let Some(gf_high) = params.gf_high {
        if gf_high == 0 {
            return Err(DecoSimError::InvalidParam {
                msg: "gf_high must be > 0".to_string(),
            });
        }
    }
    if let (Some(lo), Some(hi)) = (params.gf_low, params.gf_high) {
        if lo > hi {
            return Err(DecoSimError::InvalidParam {
                msg: format!("gf_low ({lo}) must be <= gf_high ({hi})"),
            });
        }
    }
    if let Some(sp) = params.setpoint_ppo2 {
        if sp <= 0.0 {
            return Err(DecoSimError::InvalidParam {
                msg: format!("setpoint_ppo2 ({sp}) must be > 0"),
            });
        }
    }
    if let Some(si) = params.sample_interval_sec {
        if si <= 0 {
            return Err(DecoSimError::InvalidParam {
                msg: format!("sample_interval_sec ({si}) must be > 0"),
            });
        }
    }

    // Validate gas plan: exactly one gas with switch_depth_m == None (bottom gas)
    // when gas_plan is non-empty; empty gas_plan defaults to air.
    if !params.gas_plan.is_empty() {
        let bottom_gas_count = params
            .gas_plan
            .iter()
            .filter(|g| g.switch_depth_m.is_none())
            .count();
        if bottom_gas_count != 1 {
            return Err(DecoSimError::InvalidParam {
                msg: format!(
                    "gas_plan must have exactly one gas with switch_depth_m = None (bottom gas), found {bottom_gas_count}"
                ),
            });
        }
    }

    Ok(())
}

// ============================================================================
// Gas Plan Building
// ============================================================================

/// Build gas mix list and switch schedule from user's gas plan.
///
/// Gas mixes are re-indexed by their position in the plan (0, 1, 2, ...),
/// so `GasSwitchPlan.gas.mix_index` is ignored in favour of positional order.
///
/// Returns `(gas_mixes, bottom_gas_index, switch_schedule)` where
/// `switch_schedule` is sorted by switch depth descending (deepest first).
fn build_gas_plan(plan: &[GasSwitchPlan]) -> (Vec<GasMixInput>, i32, Vec<(f64, i32)>) {
    if plan.is_empty() {
        // Default to air
        let air = GasMixInput {
            mix_index: 0,
            o2_fraction: 0.21,
            he_fraction: 0.0,
        };
        return (vec![air], 0, vec![]);
    }

    let mut gas_mixes = Vec::with_capacity(plan.len());
    let mut switch_schedule: Vec<(f64, i32)> = Vec::new();
    let mut bottom_gas_index: i32 = 0;

    for (i, gsp) in plan.iter().enumerate() {
        let mix_index = i as i32;
        gas_mixes.push(GasMixInput {
            mix_index,
            o2_fraction: gsp.gas.o2_fraction,
            he_fraction: gsp.gas.he_fraction,
        });

        if let Some(switch_depth) = gsp.switch_depth_m {
            switch_schedule.push((switch_depth, mix_index));
        } else {
            bottom_gas_index = mix_index;
        }
    }

    // Sort switches by depth descending (deepest switch first)
    switch_schedule.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));

    (gas_mixes, bottom_gas_index, switch_schedule)
}

// ============================================================================
// Sample Generation Helpers
// ============================================================================

/// Shared context for sample generation, reducing argument count.
struct SampleCtx {
    setpoint_ppo2: Option<f64>,
    surface_pressure: f64,
    temp_c: f32,
    sample_interval: i32,
    ascent_rate: f64,
}

impl SampleCtx {
    fn make_sample(&self, t_sec: i32, depth_m: f64, gasmix_index: i32) -> SampleInput {
        let ppo2 = self.setpoint_ppo2.map(|sp| {
            let ambient = depth_to_pressure(depth_m, self.surface_pressure);
            sp.min(ambient) as f32
        });

        SampleInput {
            t_sec,
            depth_m: depth_m as f32,
            temp_c: self.temp_c,
            setpoint_ppo2: ppo2,
            ceiling_m: None,
            gf99: None,
            gasmix_index: Some(gasmix_index),
            ppo2,
            tts_sec: None,
            ndl_sec: None,
            deco_stop_depth_m: None,
            at_plus_five_tts_min: None,
        }
    }
}

fn generate_descent(
    samples: &mut Vec<SampleInput>,
    target_depth_m: f64,
    descent_time_sec: i32,
    gas_index: i32,
    ctx: &SampleCtx,
) {
    // Always start at surface t=0
    samples.push(ctx.make_sample(0, 0.0, gas_index));

    let mut t = ctx.sample_interval;
    while t < descent_time_sec {
        let frac = t as f64 / descent_time_sec as f64;
        let depth = frac * target_depth_m;
        samples.push(ctx.make_sample(t, depth, gas_index));
        t += ctx.sample_interval;
    }

    // Final descent sample at target depth
    if samples.last().is_none_or(|s| s.t_sec != descent_time_sec) {
        samples.push(ctx.make_sample(descent_time_sec, target_depth_m, gas_index));
    }
}

fn generate_bottom(
    samples: &mut Vec<SampleInput>,
    target_depth_m: f64,
    descent_end_t: i32,
    bottom_time_sec: i32,
    gas_index: i32,
    ctx: &SampleCtx,
) {
    let bottom_end_t = descent_end_t + bottom_time_sec;
    let mut t = descent_end_t + ctx.sample_interval;
    while t < bottom_end_t {
        samples.push(ctx.make_sample(t, target_depth_m, gas_index));
        t += ctx.sample_interval;
    }

    // Final bottom sample
    if samples.last().is_none_or(|s| s.t_sec != bottom_end_t) {
        samples.push(ctx.make_sample(bottom_end_t, target_depth_m, gas_index));
    }
}

fn generate_ascent(
    samples: &mut Vec<SampleInput>,
    start_depth_m: f64,
    start_t: i32,
    deco_stops: &[DecoStop],
    switch_schedule: &[(f64, i32)],
    bottom_gas_index: i32,
    ctx: &SampleCtx,
) {
    let mut current_depth = start_depth_m;
    let mut current_t = start_t;
    let mut current_gas = bottom_gas_index;
    let mut switch_idx = 0; // index into switch_schedule (sorted deepest first)

    if deco_stops.is_empty() {
        // No deco: free ascent to surface
        ascend_segment(
            samples,
            &mut current_depth,
            &mut current_t,
            0.0,
            &mut current_gas,
            switch_schedule,
            &mut switch_idx,
            ctx,
        );
    } else {
        // Ascend to each stop, hold, then continue
        for stop in deco_stops {
            let stop_depth = stop.depth_m as f64;

            // Ascend from current depth to stop depth
            ascend_segment(
                samples,
                &mut current_depth,
                &mut current_t,
                stop_depth,
                &mut current_gas,
                switch_schedule,
                &mut switch_idx,
                ctx,
            );

            // Use stop's gas mix if specified
            if stop.gas_mix_index >= 0 {
                current_gas = stop.gas_mix_index;
            }

            // Hold at stop depth
            let stop_end_t = current_t + stop.duration_sec;
            let mut t = current_t + ctx.sample_interval;
            while t < stop_end_t {
                samples.push(ctx.make_sample(t, stop_depth, current_gas));
                t += ctx.sample_interval;
            }
            if current_t != stop_end_t {
                samples.push(ctx.make_sample(stop_end_t, stop_depth, current_gas));
            }
            current_t = stop_end_t;
            current_depth = stop_depth;
        }

        // Final ascent from last stop to surface
        ascend_segment(
            samples,
            &mut current_depth,
            &mut current_t,
            0.0,
            &mut current_gas,
            switch_schedule,
            &mut switch_idx,
            ctx,
        );
    }

    // Ensure final sample is at surface
    if samples.last().is_none_or(|s| s.depth_m > 0.0) {
        samples.push(ctx.make_sample(current_t, 0.0, current_gas));
    }
}

/// Ascend from current depth to target depth, checking for gas switches.
#[allow(clippy::too_many_arguments)]
fn ascend_segment(
    samples: &mut Vec<SampleInput>,
    current_depth: &mut f64,
    current_t: &mut i32,
    target_depth: f64,
    current_gas: &mut i32,
    switch_schedule: &[(f64, i32)],
    switch_idx: &mut usize,
    ctx: &SampleCtx,
) {
    if *current_depth <= target_depth {
        return;
    }

    let total_ascent_m = *current_depth - target_depth;
    let total_ascent_sec = (total_ascent_m / ctx.ascent_rate * 60.0).round() as i32;
    let total_ascent_sec = total_ascent_sec.max(1);
    let start_depth = *current_depth;
    let start_t = *current_t;

    let mut t = ctx.sample_interval;
    while t < total_ascent_sec {
        let frac = t as f64 / total_ascent_sec as f64;
        let depth = start_depth - frac * total_ascent_m;
        let depth = depth.max(target_depth);

        // Check for gas switches during ascent
        check_gas_switch(depth, current_gas, switch_schedule, switch_idx);

        samples.push(ctx.make_sample(start_t + t, depth, *current_gas));
        t += ctx.sample_interval;
    }

    // Final sample at target depth
    check_gas_switch(target_depth, current_gas, switch_schedule, switch_idx);
    let end_t = start_t + total_ascent_sec;
    // Avoid duplicate if last sample was already at this time
    if samples.last().is_none_or(|s| s.t_sec != end_t) {
        samples.push(ctx.make_sample(end_t, target_depth, *current_gas));
    }

    *current_depth = target_depth;
    *current_t = end_t;
}

/// Check if we should switch gas at the given depth.
fn check_gas_switch(
    depth: f64,
    current_gas: &mut i32,
    switch_schedule: &[(f64, i32)],
    switch_idx: &mut usize,
) {
    while *switch_idx < switch_schedule.len() {
        let (switch_depth, gas_index) = switch_schedule[*switch_idx];
        if depth <= switch_depth {
            *current_gas = gas_index;
            *switch_idx += 1;
        } else {
            break;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn air_params(depth: f64, bottom_time: i32) -> ProfileGenParams {
        ProfileGenParams {
            target_depth_m: depth,
            bottom_time_sec: bottom_time,
            descent_rate_m_min: None,
            ascent_rate_m_min: None,
            gas_plan: vec![],
            model: DecoModel::BuhlmannZhl16c,
            surface_pressure_bar: None,
            gf_low: None,
            gf_high: None,
            last_stop_depth_m: None,
            stop_interval_m: None,
            setpoint_ppo2: None,
            thalmann_pdcs: None,
            sample_interval_sec: None,
            temp_c: None,
        }
    }

    // ── Validation tests ────────────────────────────────────────────────

    #[test]
    fn test_zero_depth_rejected() {
        let params = air_params(0.0, 600);
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_negative_depth_rejected() {
        let params = air_params(-10.0, 600);
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_zero_bottom_time_rejected() {
        let params = air_params(30.0, 0);
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_empty_gas_plan_defaults_to_air() {
        let params = air_params(18.0, 600);
        let result = generate_dive_profile(params).unwrap();
        assert_eq!(result.gas_mixes.len(), 1);
        assert!((result.gas_mixes[0].o2_fraction - 0.21).abs() < 1e-6);
        assert!((result.gas_mixes[0].he_fraction).abs() < 1e-6);
    }

    #[test]
    fn test_invalid_gf_low_gt_high() {
        let mut params = air_params(30.0, 600);
        params.gf_low = Some(85);
        params.gf_high = Some(50);
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_zero_gf_low_rejected() {
        let mut params = air_params(30.0, 600);
        params.gf_low = Some(0);
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_zero_gf_high_rejected() {
        let mut params = air_params(30.0, 600);
        params.gf_high = Some(0);
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_invalid_descent_rate_rejected() {
        let mut params = air_params(30.0, 600);
        params.descent_rate_m_min = Some(0.0);
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_invalid_setpoint_rejected() {
        let mut params = air_params(30.0, 600);
        params.setpoint_ppo2 = Some(-0.5);
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_zero_setpoint_rejected() {
        let mut params = air_params(30.0, 600);
        params.setpoint_ppo2 = Some(0.0);
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_invalid_ascent_rate_rejected() {
        let mut params = air_params(30.0, 600);
        params.ascent_rate_m_min = Some(-1.0);
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_zero_ascent_rate_rejected() {
        let mut params = air_params(30.0, 600);
        params.ascent_rate_m_min = Some(0.0);
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_equal_gf_accepted() {
        let mut params = air_params(18.0, 600);
        params.gf_low = Some(85);
        params.gf_high = Some(85);
        let result = generate_dive_profile(params);
        assert!(result.is_ok(), "Equal GF low/high should be valid");
    }

    #[test]
    fn test_zero_sample_interval_rejected() {
        let mut params = air_params(30.0, 600);
        params.sample_interval_sec = Some(0);
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_negative_sample_interval_rejected() {
        let mut params = air_params(30.0, 600);
        params.sample_interval_sec = Some(-5);
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_no_bottom_gas_rejected() {
        let mut params = air_params(30.0, 600);
        params.gas_plan = vec![GasSwitchPlan {
            gas: GasMixInput {
                mix_index: 0,
                o2_fraction: 0.50,
                he_fraction: 0.0,
            },
            switch_depth_m: Some(21.0),
        }];
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_multiple_bottom_gases_rejected() {
        let mut params = air_params(30.0, 600);
        params.gas_plan = vec![
            GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 0,
                    o2_fraction: 0.21,
                    he_fraction: 0.0,
                },
                switch_depth_m: None,
            },
            GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 1,
                    o2_fraction: 0.32,
                    he_fraction: 0.0,
                },
                switch_depth_m: None,
            },
        ];
        let result = generate_dive_profile(params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    // ── Profile shape tests ─────────────────────────────────────────────

    #[test]
    fn test_descent_time_correct() {
        // 30m at 18 m/min = 100s
        let params = air_params(30.0, 600);
        let result = generate_dive_profile(params).unwrap();
        let expected_descent = (30.0_f64 / 18.0 * 60.0).round() as i32;
        assert_eq!(result.descent_end_t_sec, expected_descent);
    }

    #[test]
    fn test_bottom_end_time() {
        let params = air_params(30.0, 600);
        let result = generate_dive_profile(params).unwrap();
        // bottom_time_sec=600 includes descent, so bottom_end = 600
        assert_eq!(result.bottom_end_t_sec, 600);
    }

    #[test]
    fn test_total_time_gt_bottom_end() {
        let params = air_params(30.0, 600);
        let result = generate_dive_profile(params).unwrap();
        assert!(
            result.total_time_sec > result.bottom_end_t_sec,
            "Total time ({}) should be > bottom end ({})",
            result.total_time_sec,
            result.bottom_end_t_sec
        );
    }

    #[test]
    fn test_samples_time_ordered() {
        let params = air_params(30.0, 600);
        let result = generate_dive_profile(params).unwrap();
        for i in 1..result.samples.len() {
            assert!(
                result.samples[i].t_sec >= result.samples[i - 1].t_sec,
                "Samples not time-ordered at index {}: t={} < t={}",
                i,
                result.samples[i].t_sec,
                result.samples[i - 1].t_sec
            );
        }
    }

    // ── Sample correctness tests ────────────────────────────────────────

    #[test]
    fn test_descent_has_intermediate_samples() {
        // 30m at 18 m/min = 100s, with 10s interval → should have samples at t=10,20,...,90
        let params = air_params(30.0, 600);
        let result = generate_dive_profile(params).unwrap();
        let descent_samples: Vec<_> = result
            .samples
            .iter()
            .filter(|s| s.t_sec <= result.descent_end_t_sec)
            .collect();
        // Should have surface (t=0), intermediates, and final (t=100)
        assert!(
            descent_samples.len() >= 3,
            "Descent should have at least 3 samples (surface + intermediates + target), got {}",
            descent_samples.len()
        );
        // Intermediate sample at ~50% descent should be at ~50% depth
        let mid_sample = descent_samples
            .iter()
            .find(|s| s.t_sec > 0 && s.t_sec < result.descent_end_t_sec)
            .expect("Should have at least one intermediate descent sample");
        assert!(
            mid_sample.depth_m > 0.0 && mid_sample.depth_m < 30.0,
            "Intermediate descent sample depth should be between 0 and 30m, got {}",
            mid_sample.depth_m
        );
        // Check proportionality: depth should roughly equal (t / descent_time) * target_depth
        let expected_depth = mid_sample.t_sec as f64 / result.descent_end_t_sec as f64 * 30.0;
        assert!(
            (mid_sample.depth_m as f64 - expected_depth).abs() < 1.0,
            "Descent depth at t={} should be ~{:.1}m, got {}m",
            mid_sample.t_sec,
            expected_depth,
            mid_sample.depth_m
        );
    }

    #[test]
    fn test_descent_final_sample_at_target() {
        let params = air_params(30.0, 600);
        let result = generate_dive_profile(params).unwrap();
        // Find sample at descent_end_t
        let final_descent = result
            .samples
            .iter()
            .find(|s| s.t_sec == result.descent_end_t_sec)
            .expect("Should have a sample at descent_end_t");
        assert!(
            (final_descent.depth_m - 30.0).abs() < 0.01,
            "Final descent sample should be at target depth, got {}",
            final_descent.depth_m
        );
    }

    #[test]
    fn test_descent_depth_monotonically_increases() {
        let params = air_params(30.0, 600);
        let result = generate_dive_profile(params).unwrap();
        let descent_samples: Vec<_> = result
            .samples
            .iter()
            .filter(|s| s.t_sec <= result.descent_end_t_sec)
            .collect();
        for i in 1..descent_samples.len() {
            assert!(
                descent_samples[i].depth_m >= descent_samples[i - 1].depth_m,
                "Descent not monotonic at index {}: {} < {}",
                i,
                descent_samples[i].depth_m,
                descent_samples[i - 1].depth_m
            );
        }
    }

    #[test]
    fn test_bottom_depth_constant() {
        let params = air_params(30.0, 600);
        let result = generate_dive_profile(params).unwrap();
        let bottom_samples: Vec<_> = result
            .samples
            .iter()
            .filter(|s| s.t_sec > result.descent_end_t_sec && s.t_sec <= result.bottom_end_t_sec)
            .collect();
        assert!(!bottom_samples.is_empty());
        for s in &bottom_samples {
            assert!(
                (s.depth_m - 30.0).abs() < 0.1,
                "Bottom depth should be 30.0, got {}",
                s.depth_m
            );
        }
    }

    #[test]
    fn test_ascent_depth_non_increasing() {
        let params = air_params(30.0, 600);
        let result = generate_dive_profile(params).unwrap();
        let ascent_samples: Vec<_> = result
            .samples
            .iter()
            .filter(|s| s.t_sec >= result.bottom_end_t_sec)
            .collect();
        for i in 1..ascent_samples.len() {
            assert!(
                ascent_samples[i].depth_m <= ascent_samples[i - 1].depth_m + 0.01,
                "Ascent not non-increasing at index {}: {} > {}",
                i,
                ascent_samples[i].depth_m,
                ascent_samples[i - 1].depth_m
            );
        }
    }

    #[test]
    fn test_last_sample_at_surface() {
        let params = air_params(30.0, 600);
        let result = generate_dive_profile(params).unwrap();
        let last = result.samples.last().unwrap();
        assert!(
            last.depth_m.abs() < 0.01,
            "Last sample should be at surface, got depth={}",
            last.depth_m
        );
    }

    // ── Gas switch tests ────────────────────────────────────────────────

    #[test]
    fn test_bottom_gas_used_during_descent() {
        let mut params = air_params(30.0, 600);
        params.gas_plan = vec![
            GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 0,
                    o2_fraction: 0.21,
                    he_fraction: 0.35,
                },
                switch_depth_m: None,
            },
            GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 1,
                    o2_fraction: 0.50,
                    he_fraction: 0.0,
                },
                switch_depth_m: Some(21.0),
            },
        ];
        let result = generate_dive_profile(params).unwrap();
        let descent_samples: Vec<_> = result
            .samples
            .iter()
            .filter(|s| s.t_sec <= result.descent_end_t_sec)
            .collect();
        for s in &descent_samples {
            assert_eq!(
                s.gasmix_index,
                Some(0),
                "Descent should use bottom gas (index 0), got {:?}",
                s.gasmix_index
            );
        }
    }

    #[test]
    fn test_gas_switch_occurs_at_depth() {
        let mut params = air_params(40.0, 1200);
        params.gf_low = Some(30);
        params.gf_high = Some(70);
        params.gas_plan = vec![
            GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 0,
                    o2_fraction: 0.21,
                    he_fraction: 0.0,
                },
                switch_depth_m: None,
            },
            GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 1,
                    o2_fraction: 0.50,
                    he_fraction: 0.0,
                },
                switch_depth_m: Some(21.0),
            },
        ];
        let result = generate_dive_profile(params).unwrap();

        // Find first sample with gas index 1
        let switch_sample = result.samples.iter().find(|s| s.gasmix_index == Some(1));
        assert!(switch_sample.is_some(), "Should have switched to gas 1");
        let switch_depth = switch_sample.unwrap().depth_m;
        assert!(
            switch_depth <= 21.0 + 0.5,
            "Gas switch should happen at or shallower than 21m, got {switch_depth}m"
        );
    }

    #[test]
    fn test_multiple_gas_switches() {
        // Trimix bottom + EAN50@21m + O2@6m
        let mut params = air_params(45.0, 1200);
        params.gf_low = Some(30);
        params.gf_high = Some(70);
        params.gas_plan = vec![
            GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 0,
                    o2_fraction: 0.21,
                    he_fraction: 0.35,
                },
                switch_depth_m: None,
            },
            GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 1,
                    o2_fraction: 0.50,
                    he_fraction: 0.0,
                },
                switch_depth_m: Some(21.0),
            },
            GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 2,
                    o2_fraction: 1.0,
                    he_fraction: 0.0,
                },
                switch_depth_m: Some(6.0),
            },
        ];
        let result = generate_dive_profile(params).unwrap();

        // Should have samples with gas indices 0, 1, and 2
        let gas_indices: std::collections::HashSet<i32> = result
            .samples
            .iter()
            .filter_map(|s| s.gasmix_index)
            .collect();
        assert!(gas_indices.contains(&0), "Should use bottom gas 0");
        assert!(gas_indices.contains(&1), "Should use EAN50 (gas 1)");
        assert!(gas_indices.contains(&2), "Should use O2 (gas 2)");
    }

    // ── CCR tests ───────────────────────────────────────────────────────

    #[test]
    fn test_ccr_ppo2_set_on_all_samples() {
        let mut params = air_params(30.0, 600);
        params.setpoint_ppo2 = Some(1.3);
        let result = generate_dive_profile(params).unwrap();
        for s in &result.samples {
            assert!(
                s.ppo2.is_some(),
                "CCR sample at t={} should have ppo2",
                s.t_sec
            );
            assert!(
                s.setpoint_ppo2.is_some(),
                "CCR sample at t={} should have setpoint_ppo2",
                s.t_sec
            );
        }
    }

    #[test]
    fn test_ccr_ppo2_clamped_near_surface() {
        let mut params = air_params(30.0, 600);
        params.setpoint_ppo2 = Some(1.3);
        let result = generate_dive_profile(params).unwrap();
        // Surface sample: ambient ≈ 1.013 bar, so PPO2 should be clamped below setpoint
        let surface_sample = &result.samples[0];
        assert!(surface_sample.depth_m < 0.01);
        let ppo2 = surface_sample.ppo2.unwrap();
        assert!(
            ppo2 <= 1.014, // ambient at surface ≈ 1.013
            "Surface PPO2 ({ppo2}) should be clamped to ambient pressure"
        );
    }

    // ── Deco integration tests ──────────────────────────────────────────

    #[test]
    fn test_shallow_no_deco() {
        // 12m for 30 minutes on air — well within NDL
        let params = air_params(12.0, 1800);
        let result = generate_dive_profile(params).unwrap();
        assert!(
            result.deco_result.deco_stops.is_empty(),
            "Shallow dive should have no deco stops"
        );
        assert_eq!(result.deco_result.total_deco_time_sec, 0);
    }

    #[test]
    fn test_deep_dive_has_deco() {
        // 40m for 20 minutes on air with GF 50/80 — should have deco
        let mut params = air_params(40.0, 1200);
        params.gf_low = Some(50);
        params.gf_high = Some(80);
        let result = generate_dive_profile(params).unwrap();
        // The pass1 result generated stops that shaped the ascent.
        // The pass2 result should show TTS > 0 at some point during the dive.
        let max_tts = result.deco_result.max_tts_sec;
        assert!(max_tts > 0, "Deep dive should have TTS > 0, got {max_tts}");
        assert!(
            result.total_time_sec > result.bottom_end_t_sec + 300,
            "Deep dive total time should be well beyond bottom end"
        );
    }

    #[test]
    fn test_conservative_gf_more_deco() {
        // Same dive with different GFs
        let mut permissive = air_params(40.0, 1200);
        permissive.gf_low = Some(70);
        permissive.gf_high = Some(90);

        let mut conservative = air_params(40.0, 1200);
        conservative.gf_low = Some(30);
        conservative.gf_high = Some(70);

        let result_permissive = generate_dive_profile(permissive).unwrap();
        let result_conservative = generate_dive_profile(conservative).unwrap();

        assert!(
            result_conservative.total_time_sec >= result_permissive.total_time_sec,
            "Conservative GF ({}) should produce >= total time than permissive ({})",
            result_conservative.total_time_sec,
            result_permissive.total_time_sec,
        );
    }

    // ── Custom sample interval ──────────────────────────────────────────

    #[test]
    fn test_custom_sample_interval() {
        let mut params = air_params(18.0, 600);
        params.sample_interval_sec = Some(5);
        let result = generate_dive_profile(params).unwrap();
        // With 5s intervals we should have more samples than with default 10s
        let mut default_params = air_params(18.0, 600);
        default_params.sample_interval_sec = Some(10);
        let result_default = generate_dive_profile(default_params).unwrap();
        assert!(
            result.samples.len() > result_default.samples.len(),
            "5s interval ({}) should produce more samples than 10s ({})",
            result.samples.len(),
            result_default.samples.len()
        );
    }

    // ── Sample count precision tests ──────────────────────────────────

    #[test]
    fn test_bottom_has_intermediate_samples() {
        // 30m for 600s with 10s interval → should have samples during bottom
        let params = air_params(30.0, 600);
        let result = generate_dive_profile(params).unwrap();
        let bottom_samples: Vec<_> = result
            .samples
            .iter()
            .filter(|s| s.t_sec > result.descent_end_t_sec && s.t_sec <= result.bottom_end_t_sec)
            .collect();
        // 600s / 10s = 60 samples expected during bottom
        assert!(
            bottom_samples.len() >= 10,
            "Bottom should have many samples with 10s interval over 600s, got {}",
            bottom_samples.len()
        );
        // Final bottom sample should be at bottom_end_t
        assert_eq!(
            bottom_samples.last().unwrap().t_sec,
            result.bottom_end_t_sec,
            "Last bottom sample should be at bottom_end_t"
        );
    }

    #[test]
    fn test_deco_stop_has_hold_samples() {
        // Deep dive with deco — check that stop holds produce samples
        let mut params = air_params(40.0, 1200);
        params.gf_low = Some(50);
        params.gf_high = Some(80);
        params.sample_interval_sec = Some(10);
        let result = generate_dive_profile(params).unwrap();

        // With deco, ascent samples should include constant-depth holds
        let ascent_samples: Vec<_> = result
            .samples
            .iter()
            .filter(|s| s.t_sec > result.bottom_end_t_sec)
            .collect();

        // Find consecutive samples at the same depth (hold)
        let has_hold = ascent_samples
            .windows(2)
            .any(|w| (w[0].depth_m - w[1].depth_m).abs() < 0.01 && w[0].depth_m > 0.1);
        assert!(
            has_hold,
            "Deco dive should have hold samples at constant depth during stops"
        );
    }

    #[test]
    fn test_profile_ends_at_zero_depth() {
        // This specifically tests that the surface-ensure code runs
        let params = air_params(18.0, 600);
        let result = generate_dive_profile(params).unwrap();
        let last = result.samples.last().unwrap();
        assert!(
            last.depth_m.abs() < 0.01,
            "Profile must end at depth 0, got {}",
            last.depth_m
        );
    }

    // ── Sanity check: 30m/20min air profile ─────────────────────────────

    #[test]
    fn test_sanity_30m_20min_air() {
        let params = air_params(30.0, 1200);
        let result = generate_dive_profile(params).unwrap();

        // Descent: 30m at 18 m/min = 100s
        assert_eq!(result.descent_end_t_sec, 100);

        // Bottom end: bottom_time_sec=1200 includes descent, so bottom_end = 1200
        assert_eq!(result.bottom_end_t_sec, 1200);

        // Total should be reasonable
        assert!(
            result.total_time_sec > 1200,
            "Total time ({}) should be > bottom end (1200)",
            result.total_time_sec
        );
        assert!(
            result.total_time_sec < 3600,
            "Total time ({}) should be < 60 min for a 30m/20min air dive",
            result.total_time_sec
        );

        // Profile starts at surface and ends at surface
        assert!(result.samples[0].depth_m.abs() < 0.01);
        assert!(result.samples.last().unwrap().depth_m.abs() < 0.01);

        // Max depth should be 30m
        let max_depth = result
            .samples
            .iter()
            .map(|s| s.depth_m)
            .fold(0.0_f32, f32::max);
        assert!(
            (max_depth - 30.0).abs() < 0.5,
            "Max depth should be ~30m, got {max_depth}"
        );
    }

    // ── Smoke / integration tests for real-world scenarios ───────────────
    //
    // These reproduce actual dive profiles to catch regressions and
    // validate that the engine produces physically reasonable results.

    #[test]
    fn smoke_ccr_150ft_40min_buhlmann_gf50_90() {
        // CCR dive: 150ft (45.7m), 40 min bottom (including descent), Tx 15/15 diluent, SP 1.2, GF 50/90
        // At 18 m/min descent, descent takes ~2.5 min → ~37.5 min at depth.
        // DP4 with ~9 m/min descent gives 5 min descent → 35 min at depth → 77 min total.
        // Faster descent = more time at depth = slightly more deco than DP4.
        let params = ProfileGenParams {
            target_depth_m: 45.72,
            bottom_time_sec: 40 * 60,
            descent_rate_m_min: Some(18.0),
            ascent_rate_m_min: Some(9.0),
            gas_plan: vec![GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 0,
                    o2_fraction: 0.15,
                    he_fraction: 0.15,
                },
                switch_depth_m: None,
            }],
            model: DecoModel::BuhlmannZhl16c,
            surface_pressure_bar: None,
            gf_low: Some(50),
            gf_high: Some(90),
            last_stop_depth_m: None,
            stop_interval_m: None,
            setpoint_ppo2: Some(1.2),
            thalmann_pdcs: None,
            sample_interval_sec: None,
            temp_c: None,
        };
        let result = generate_dive_profile(params).unwrap();
        let total_min = result.total_time_sec / 60;
        assert!(
            (70..=100).contains(&total_min),
            "CCR 150ft/40min GF50/90: total {total_min} min (expected 70-100)"
        );
        assert!(
            result.deco_result.max_tts_sec > 0,
            "CCR 150ft/40min should have TTS > 0"
        );
    }

    #[test]
    fn smoke_ccr_200ft_29min_buhlmann_gf50_90() {
        // CCR dive: 200ft (61m), 29 min bottom (including descent), Tx 18/25 diluent, SP 1.2, GF 50/90
        // At 18 m/min descent, descent takes ~3.4 min → ~25.6 min at depth.
        // DP4 with ~8.7 m/min descent gives 7 min descent → 22 min at depth → 76 min total.
        let params = ProfileGenParams {
            target_depth_m: 60.96,
            bottom_time_sec: 29 * 60,
            descent_rate_m_min: Some(18.0),
            ascent_rate_m_min: Some(9.0),
            gas_plan: vec![GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 0,
                    o2_fraction: 0.18,
                    he_fraction: 0.25,
                },
                switch_depth_m: None,
            }],
            model: DecoModel::BuhlmannZhl16c,
            surface_pressure_bar: None,
            gf_low: Some(50),
            gf_high: Some(90),
            last_stop_depth_m: None,
            stop_interval_m: None,
            setpoint_ppo2: Some(1.2),
            thalmann_pdcs: None,
            sample_interval_sec: None,
            temp_c: None,
        };
        let result = generate_dive_profile(params).unwrap();
        let total_min = result.total_time_sec / 60;
        assert!(
            (75..=110).contains(&total_min),
            "CCR 200ft/29min GF50/90: total {total_min} min (expected 75-110)"
        );
    }

    #[test]
    fn smoke_ccr_150ft_40min_thalmann_pdcs23() {
        // Same CCR profile but with Thalmann 2.3% P_DCS
        let params = ProfileGenParams {
            target_depth_m: 45.72,
            bottom_time_sec: 40 * 60,
            descent_rate_m_min: Some(18.0),
            ascent_rate_m_min: Some(9.0),
            gas_plan: vec![GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 0,
                    o2_fraction: 0.15,
                    he_fraction: 0.15,
                },
                switch_depth_m: None,
            }],
            model: DecoModel::ThalmannElDca,
            surface_pressure_bar: None,
            gf_low: None,
            gf_high: None,
            last_stop_depth_m: None,
            stop_interval_m: None,
            setpoint_ppo2: Some(1.2),
            thalmann_pdcs: Some(ThalmannPdcs::Pdcs23),
            sample_interval_sec: None,
            temp_c: None,
        };
        let result = generate_dive_profile(params).unwrap();
        let total_min = result.total_time_sec / 60;
        assert!(
            total_min < 180,
            "Thalmann CCR 150ft/40min: total {total_min} min is unreasonable (expected <180)"
        );
    }

    #[test]
    fn smoke_diag_simple_air_30m_20min() {
        // Simple air dive that should be easy to verify: 30m/20min GF 100/100
        let mut params = air_params(30.0, 1200);
        params.gf_low = Some(100);
        params.gf_high = Some(100);
        let result = generate_dive_profile(params).unwrap();
        let total_min = result.total_time_sec / 60;
        let deco_stops = &result.deco_result.deco_stops;
        eprintln!("=== Air 30m/20min GF100/100 ===");
        eprintln!(
            "Total: {} min, Bottom end: {} sec",
            total_min, result.bottom_end_t_sec
        );
        eprintln!(
            "Stops: {:?}",
            deco_stops
                .iter()
                .map(|s| format!("{}m {}s", s.depth_m, s.duration_sec))
                .collect::<Vec<_>>()
        );
        eprintln!(
            "Max ceiling: {}m, Max GF99: {}, Max TTS: {}s",
            result.deco_result.max_ceiling_m,
            result.deco_result.max_gf99,
            result.deco_result.max_tts_sec
        );
        eprintln!("Truncated: {}", result.truncated);
        eprintln!("Sample count: {}", result.samples.len());
        // 30m/20min on air at GF 100/100 should be within NDL or have minimal deco
        assert!(
            total_min < 60,
            "Air 30m/20min GF100/100: total {total_min} min is unreasonable"
        );
    }

    #[test]
    fn smoke_diag_air_40m_20min_gf50_80() {
        // 40m/20min on air with GF 50/80 — should have moderate deco
        let mut params = air_params(40.0, 1200);
        params.gf_low = Some(50);
        params.gf_high = Some(80);
        let result = generate_dive_profile(params).unwrap();
        let total_min = result.total_time_sec / 60;
        let deco_stops = &result.deco_result.deco_stops;
        eprintln!("=== Air 40m/20min GF50/80 ===");
        eprintln!(
            "Total: {} min, Bottom end: {} sec",
            total_min, result.bottom_end_t_sec
        );
        eprintln!(
            "Stops: {:?}",
            deco_stops
                .iter()
                .map(|s| format!("{}m {}s", s.depth_m, s.duration_sec))
                .collect::<Vec<_>>()
        );
        eprintln!(
            "Max ceiling: {}m, Max TTS: {}s",
            result.deco_result.max_ceiling_m, result.deco_result.max_tts_sec
        );
        eprintln!("Truncated: {}", result.truncated);
        // 88 min is plausible for air at 40m with conservative GF 50/80 (single gas deco)
        assert!(
            total_min < 120,
            "Air 40m/20min GF50/80: total {total_min} min unreasonable"
        );
    }

    #[test]
    fn smoke_diag_oc_150ft_gf_comparison() {
        // Compare deco times across GF settings for OC 150ft/40min Tx21/35+Nx50
        for (gf_lo, gf_hi) in [(20, 85), (30, 85), (50, 85), (50, 90)] {
            let params = ProfileGenParams {
                target_depth_m: 45.72,
                bottom_time_sec: 40 * 60,
                descent_rate_m_min: Some(18.0),
                ascent_rate_m_min: Some(9.0),
                gas_plan: vec![
                    GasSwitchPlan {
                        gas: GasMixInput {
                            mix_index: 0,
                            o2_fraction: 0.21,
                            he_fraction: 0.35,
                        },
                        switch_depth_m: None,
                    },
                    GasSwitchPlan {
                        gas: GasMixInput {
                            mix_index: 1,
                            o2_fraction: 0.50,
                            he_fraction: 0.0,
                        },
                        switch_depth_m: Some(21.0),
                    },
                ],
                model: DecoModel::BuhlmannZhl16c,
                surface_pressure_bar: None,
                gf_low: Some(gf_lo),
                gf_high: Some(gf_hi),
                last_stop_depth_m: None,
                stop_interval_m: None,
                setpoint_ppo2: None,
                thalmann_pdcs: None,
                sample_interval_sec: None,
                temp_c: None,
            };
            let result = generate_dive_profile(params).unwrap();
            let total_min = result.total_time_sec / 60;
            let deco_min = (result.total_time_sec - result.bottom_end_t_sec) / 60;
            eprintln!(
                "GF {gf_lo}/{gf_hi}: total={total_min} min, deco={deco_min} min, truncated={}",
                result.truncated
            );
            if gf_lo == 50 && gf_hi == 85 {
                // Dump stop-by-stop for diagnosis
                let mut prev_d: f32 = 99.0;
                let mut hold_start = 0i32;
                for s in &result.samples {
                    if s.t_sec >= result.bottom_end_t_sec && (s.depth_m - prev_d).abs() > 0.3 {
                        if hold_start > 0 && prev_d > 0.1 {
                            eprintln!(
                                "  HOLD {:.0}m: {} sec ({:.1} min)",
                                prev_d,
                                s.t_sec - hold_start,
                                (s.t_sec - hold_start) as f64 / 60.0
                            );
                        }
                        prev_d = s.depth_m;
                        hold_start = s.t_sec;
                    }
                }
            }
        }
    }

    #[test]
    fn smoke_diag_oc_vs_dp4() {
        // OC 150ft/40min Tx21/35 + Nx50 at 70ft, compared to Decoplanner 4.
        // DP4 descent: 3 min (150ft at ~50 ft/min = 15.24 m/min)
        // DP4 bottom time = 40 min from surface = 3 min descent + 37 min at depth.
        //
        // DP4 GF 20/85: total 94 min
        //   Stops: 90ft(1), 80ft(1), 70ft(1), 60ft(2), 50ft(3), 40ft(4), 30ft(6), 20ft(11), 10ft(22)
        // DP4 GF 50/90: total 88 min

        fn print_profile(label: &str, r: &ProfileGenResult) {
            let total = r.total_time_sec / 60;
            let deco = (r.total_time_sec - r.bottom_end_t_sec) / 60;
            eprintln!("\n=== {label} ===");
            eprintln!("Total: {total} min, Deco phase: {deco} min");
            let mut prev_d: f32 = 99.0;
            let mut hold_start = 0i32;
            for s in &r.samples {
                if s.t_sec >= r.bottom_end_t_sec && (s.depth_m - prev_d).abs() > 0.3 {
                    if hold_start > 0 && prev_d > 0.1 {
                        let dur = s.t_sec - hold_start;
                        if dur > 30 {
                            eprintln!(
                                "  {:.0}ft ({:.0}m): {:.1} min",
                                prev_d * 3.28084,
                                prev_d,
                                dur as f64 / 60.0
                            );
                        }
                    }
                    prev_d = s.depth_m;
                    hold_start = s.t_sec;
                }
            }
        }

        let make_oc_params = |gf_lo, gf_hi, bottom_sec, descent_rate| ProfileGenParams {
            target_depth_m: 45.72,
            bottom_time_sec: bottom_sec,
            descent_rate_m_min: Some(descent_rate),
            ascent_rate_m_min: Some(9.0),
            gas_plan: vec![
                GasSwitchPlan {
                    gas: GasMixInput {
                        mix_index: 0,
                        o2_fraction: 0.21,
                        he_fraction: 0.35,
                    },
                    switch_depth_m: None,
                },
                GasSwitchPlan {
                    gas: GasMixInput {
                        mix_index: 1,
                        o2_fraction: 0.50,
                        he_fraction: 0.0,
                    },
                    switch_depth_m: Some(21.0),
                },
            ],
            model: DecoModel::BuhlmannZhl16c,
            surface_pressure_bar: None,
            gf_low: Some(gf_lo),
            gf_high: Some(gf_hi),
            last_stop_depth_m: None,
            stop_interval_m: None,
            setpoint_ppo2: None,
            thalmann_pdcs: None,
            sample_interval_sec: None,
            temp_c: None,
        };

        // DP4 uses 40 min bottom time (including descent), descent ~15.24 m/min
        let r1 = generate_dive_profile(make_oc_params(20, 85, 40 * 60, 15.24)).unwrap();
        print_profile("OC 150ft Tx21/35+Nx50 GF20/85 (DP4 ref: 94 min)", &r1);
        let total1 = r1.total_time_sec / 60;
        assert!(
            (total1 - 94).unsigned_abs() <= 5,
            "OC GF20/85: total {total1} min, expected ~94 (DP4), tolerance ±5"
        );

        let r2 = generate_dive_profile(make_oc_params(50, 90, 40 * 60, 15.24)).unwrap();
        print_profile("OC 150ft Tx21/35+Nx50 GF50/90 (DP4 ref: 88 min)", &r2);
        let total2 = r2.total_time_sec / 60;
        assert!(
            (total2 - 88).unsigned_abs() <= 5,
            "OC GF50/90: total {total2} min, expected ~88 (DP4), tolerance ±5"
        );
    }

    #[test]
    fn smoke_diag_ccr_vs_dp4() {
        // Compare against Decoplanner 4 reference values.
        // bottom_time_sec includes descent (matching DP4 convention).
        //
        // DP4 Profile 1: CCR 150ft/40min, Tx 15/15 dil, SP 1.2, GF 50/90
        //   Total: 77 min, stops: 60ft(1), 50ft(3), 40ft(3), 30ft(6), 20ft(7), 10ft(13)
        //   Descent: 5 min (~30 ft/min = 9.14 m/min)
        //
        // DP4 Profile 2: CCR 200ft/29min, Tx 16/25 dil, SP 1.2, GF 50/90
        //   Total: 76 min, stops: 90ft(1), 80ft(1), 70ft(2), 60ft(3), 50ft(3), 40ft(4), 30ft(6), 20ft(9), 10ft(14)
        //   Descent: 7 min (~28.6 ft/min = 8.7 m/min)

        fn print_profile(label: &str, r: &ProfileGenResult) {
            let total = r.total_time_sec / 60;
            let deco = (r.total_time_sec - r.bottom_end_t_sec) / 60;
            eprintln!("\n=== {label} ===");
            eprintln!("Total: {total} min, Deco phase: {deco} min");
            let mut prev_d: f32 = 99.0;
            let mut hold_start = 0i32;
            for s in &r.samples {
                if s.t_sec >= r.bottom_end_t_sec && (s.depth_m - prev_d).abs() > 0.3 {
                    if hold_start > 0 && prev_d > 0.1 {
                        let dur = s.t_sec - hold_start;
                        if dur > 30 {
                            eprintln!(
                                "  {:.0}ft ({:.0}m): {:.1} min",
                                prev_d * 3.28084,
                                prev_d,
                                dur as f64 / 60.0
                            );
                        }
                    }
                    prev_d = s.depth_m;
                    hold_start = s.t_sec;
                }
            }
        }

        // --- Profile 1: CCR 150ft, 40 min bottom time (including descent) ---
        let r1 = generate_dive_profile(ProfileGenParams {
            target_depth_m: 45.72,
            bottom_time_sec: 40 * 60,
            descent_rate_m_min: Some(9.14),
            ascent_rate_m_min: Some(9.0),
            gas_plan: vec![GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 0,
                    o2_fraction: 0.15,
                    he_fraction: 0.15,
                },
                switch_depth_m: None,
            }],
            model: DecoModel::BuhlmannZhl16c,
            surface_pressure_bar: None,
            gf_low: Some(50),
            gf_high: Some(90),
            last_stop_depth_m: None,
            stop_interval_m: None,
            setpoint_ppo2: Some(1.2),
            thalmann_pdcs: None,
            sample_interval_sec: None,
            temp_c: None,
        })
        .unwrap();
        print_profile("CCR 150ft/40min GF50/90 (DP4 ref: 77 min)", &r1);
        let total1 = r1.total_time_sec / 60;
        assert!(
            (total1 - 77).unsigned_abs() <= 5,
            "CCR 150ft: total {total1} min, expected ~77 (DP4), tolerance ±5"
        );

        // --- Profile 2: CCR 200ft, 29 min bottom time (including descent) ---
        let r2 = generate_dive_profile(ProfileGenParams {
            target_depth_m: 60.96,
            bottom_time_sec: 29 * 60,
            descent_rate_m_min: Some(8.7),
            ascent_rate_m_min: Some(9.0),
            gas_plan: vec![GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 0,
                    o2_fraction: 0.16,
                    he_fraction: 0.25,
                },
                switch_depth_m: None,
            }],
            model: DecoModel::BuhlmannZhl16c,
            surface_pressure_bar: None,
            gf_low: Some(50),
            gf_high: Some(90),
            last_stop_depth_m: None,
            stop_interval_m: None,
            setpoint_ppo2: Some(1.2),
            thalmann_pdcs: None,
            sample_interval_sec: None,
            temp_c: None,
        })
        .unwrap();
        print_profile("CCR 200ft/22min-at-depth GF50/90 (DP4 ref: 76 min)", &r2);
        let total2 = r2.total_time_sec / 60;
        assert!(
            (total2 - 76).unsigned_abs() <= 5,
            "CCR 200ft: total {total2} min, expected ~76 (DP4), tolerance ±5"
        );
    }

    #[test]
    #[ignore] // Known: single-gas deco with GF20 produces very long stops; needs gas-switch-aware planner
    fn smoke_diag_trimix_46m_40min_gf20_85() {
        // 46m/40min on Tx 21/35 with GF 20/85 — NO deco gas, single gas dive
        let params = ProfileGenParams {
            target_depth_m: 45.72,
            bottom_time_sec: 40 * 60,
            descent_rate_m_min: Some(18.0),
            ascent_rate_m_min: Some(9.0),
            gas_plan: vec![GasSwitchPlan {
                gas: GasMixInput {
                    mix_index: 0,
                    o2_fraction: 0.21,
                    he_fraction: 0.35,
                },
                switch_depth_m: None,
            }],
            model: DecoModel::BuhlmannZhl16c,
            surface_pressure_bar: None,
            gf_low: Some(20),
            gf_high: Some(85),
            last_stop_depth_m: None,
            stop_interval_m: None,
            setpoint_ppo2: None,
            thalmann_pdcs: None,
            sample_interval_sec: None,
            temp_c: None,
        };
        let result = generate_dive_profile(params).unwrap();
        let total_min = result.total_time_sec / 60;
        let deco_stops = &result.deco_result.deco_stops;
        eprintln!("=== Tx21/35 46m/40min GF20/85 (single gas, no deco gas) ===");
        eprintln!(
            "Total: {} min, Bottom end: {} sec",
            total_min, result.bottom_end_t_sec
        );
        eprintln!(
            "Stops: {:?}",
            deco_stops
                .iter()
                .map(|s| format!("{}m {}s", s.depth_m, s.duration_sec))
                .collect::<Vec<_>>()
        );
        eprintln!(
            "Max ceiling: {}m, Max TTS: {}s",
            result.deco_result.max_ceiling_m, result.deco_result.max_tts_sec
        );
        eprintln!("Truncated: {}", result.truncated);
        // Single gas deco on 21% O2 will be long but should still be under 200 min total
        assert!(
            total_min < 200,
            "Tx21/35 46m/40min GF20/85: total {total_min} min unreasonable"
        );
    }

    #[test]
    fn smoke_oc_150ft_40min_trimix_buhlmann() {
        // OC dive: 150ft, 40 min, Tx 21/35 bottom, Nx50 deco at 70ft
        let params = ProfileGenParams {
            target_depth_m: 45.72,
            bottom_time_sec: 40 * 60,
            descent_rate_m_min: Some(18.0),
            ascent_rate_m_min: Some(9.0),
            gas_plan: vec![
                GasSwitchPlan {
                    gas: GasMixInput {
                        mix_index: 0,
                        o2_fraction: 0.21,
                        he_fraction: 0.35,
                    },
                    switch_depth_m: None,
                },
                GasSwitchPlan {
                    gas: GasMixInput {
                        mix_index: 1,
                        o2_fraction: 0.50,
                        he_fraction: 0.0,
                    },
                    switch_depth_m: Some(21.0), // ~70ft
                },
            ],
            model: DecoModel::BuhlmannZhl16c,
            surface_pressure_bar: None,
            gf_low: Some(20),
            gf_high: Some(85),
            last_stop_depth_m: None,
            stop_interval_m: None,
            setpoint_ppo2: None,
            thalmann_pdcs: None,
            sample_interval_sec: None,
            temp_c: None,
        };
        let result = generate_dive_profile(params).unwrap();
        let total_min = result.total_time_sec / 60;
        let deco_min = (result.total_time_sec - result.bottom_end_t_sec) / 60;
        eprintln!("=== OC Tx21/35+Nx50 150ft/40min GF20/85 ===");
        eprintln!("Total: {total_min} min, Deco: {deco_min} min");
        eprintln!(
            "Bottom end: {}s, Descent end: {}s",
            result.bottom_end_t_sec, result.descent_end_t_sec
        );
        eprintln!(
            "Max ceiling: {}m, Max TTS: {}s",
            result.deco_result.max_ceiling_m, result.deco_result.max_tts_sec
        );
        eprintln!("Truncated: {}", result.truncated);
        // Print the actual ascent profile to see where time is spent
        let mut prev_depth: f32 = 99.0;
        for s in &result.samples {
            if s.t_sec >= result.bottom_end_t_sec && (s.depth_m - prev_depth).abs() > 0.5 {
                eprintln!(
                    "  t={}s depth={:.1}m gas={:?} ceil={:?} tts={:?}",
                    s.t_sec, s.depth_m, s.gasmix_index, s.ceiling_m, s.tts_sec
                );
                prev_depth = s.depth_m;
            }
        }
        // Count samples at each depth during ascent
        let ascent_samples: Vec<_> = result
            .samples
            .iter()
            .filter(|s| s.t_sec >= result.bottom_end_t_sec)
            .collect();
        eprintln!("Ascent samples: {}", ascent_samples.len());
        assert!(
            total_min < 250,
            "OC 150ft/40min GF20/85: total {total_min} min is unreasonable (expected <250)"
        );
        assert!(
            deco_min > 10,
            "OC 150ft/40min GF20/85: should have meaningful deco, got {deco_min} min"
        );
    }
}
