//! Thalmann EL-DCA decompression engine.
//!
//! Implements the Thalmann Exponential-Linear Decompression and Computing
//! Algorithm with asymmetric gas kinetics and MPTT ceiling computation.
//!
//! Key differences from Bühlmann:
//! - Washout transitions from exponential to linear when tissue supersaturation
//!   exceeds a threshold (the "crossover" mechanism).
//! - M-values are depth-dependent linear functions (MPTT tables) instead of a/b.
//! - Compartment count varies by parameter set (3-9 vs fixed 16).
//!
//! Reference: NEDU TR 18-05 (Doolette, Murphy, Gerth 2018).

use super::shared::*;
use super::thalmann_params::*;
use super::types::*;

// ============================================================================
// Thalmann Engine
// ============================================================================

pub(crate) struct ThalmannEngine;

impl ThalmannEngine {
    pub(crate) fn simulate(&self, params: &DecoSimParams) -> Result<DecoSimResult, DecoSimError> {
        // Validate inputs
        if params.samples.is_empty() {
            return Err(DecoSimError::EmptySamples {
                msg: "No samples provided".to_string(),
            });
        }

        let surface_p = params
            .surface_pressure_bar
            .unwrap_or(DEFAULT_SURFACE_PRESSURE);
        let ascent_rate = params.ascent_rate_m_min.unwrap_or(9.0);
        let last_stop_depth = params.last_stop_depth_m.unwrap_or(3.0);
        let stop_interval = params.stop_interval_m.unwrap_or(3.0);

        if ascent_rate <= 0.0 || stop_interval <= 0.0 || last_stop_depth <= 0.0 {
            return Err(DecoSimError::InvalidParam {
                msg: format!(
                    "ascent_rate ({ascent_rate}), stop_interval ({stop_interval}), \
                     and last_stop_depth ({last_stop_depth}) must be > 0"
                ),
            });
        }

        let thal_params = &XVAL_HE_9_023;
        if let Err(msg) = thal_params.validate() {
            return Err(DecoSimError::InvalidParam { msg });
        }

        // Build gas mix lookup
        let mut gas_lookup: std::collections::HashMap<i32, (f64, f64)> =
            std::collections::HashMap::new();
        for mix in &params.gas_mixes {
            gas_lookup.insert(mix.mix_index, (mix.o2_fraction, mix.he_fraction));
        }
        let default_gas = gas_lookup.get(&0).copied().unwrap_or((AIR_FO2, 0.0));
        let mut current_fo2 = default_gas.0;
        let mut current_fhe = default_gas.1;

        let mut tissues = ThalmannTissueState::surface_equilibrium(surface_p, thal_params);
        let mut points = Vec::with_capacity(params.samples.len());
        let mut max_ceiling_m: f32 = 0.0;
        let mut max_gf99: f32 = 0.0;
        let mut max_tts_sec: i32 = 0;

        for (idx, sample) in params.samples.iter().enumerate() {
            // Update tissues for time interval
            if idx > 0 {
                let prev = &params.samples[idx - 1];
                let dt_sec = (sample.t_sec - prev.t_sec) as f64;
                let avg_depth_m = ((prev.depth_m as f64 + sample.depth_m as f64) / 2.0).max(0.0);
                let ambient_p = depth_to_pressure(avg_depth_m, surface_p);

                let (fn2, fhe) = inspired_fractions(
                    current_fo2,
                    current_fhe,
                    prev.ppo2.map(|v| v as f64),
                    ambient_p,
                );

                // Convert to fsw units for tissue update
                let ambient_fsw = bar_to_fsw(ambient_p);
                let f_inert = fn2 + fhe;
                let p_inspired_fsw = (ambient_fsw - PACO2_FSW) * f_inert;

                // Compute rates of change for E-L linear term
                let depth1_fsw = meters_to_fsw((prev.depth_m as f64).max(0.0));
                let depth2_fsw = meters_to_fsw((sample.depth_m as f64).max(0.0));
                let r_ambient_fsw = if dt_sec > 0.0 {
                    (depth2_fsw - depth1_fsw) / dt_sec
                } else {
                    0.0
                };
                let r_inspired_fsw = r_ambient_fsw * f_inert;

                tissues.update(
                    dt_sec,
                    p_inspired_fsw,
                    ambient_fsw,
                    r_inspired_fsw,
                    r_ambient_fsw,
                    thal_params,
                );
            }

            // Gas switch
            if let Some(mix_idx) = sample.gasmix_index {
                if let Some(&(fo2, fhe)) = gas_lookup.get(&mix_idx) {
                    current_fo2 = fo2;
                    current_fhe = fhe;
                }
            }

            let current_depth_m = (sample.depth_m as f64).max(0.0);

            // Compute ceiling
            let ceiling_fsw = tissues.ceiling_fsw(thal_params);
            let ceiling_depth_m = fsw_to_meters(ceiling_fsw.max(0.0));
            let ceiling_m = round_up_to_stop(ceiling_depth_m, stop_interval);

            // Utilization (maps to gf99 / surface_gf)
            let current_depth_fsw = meters_to_fsw(current_depth_m);
            let (util_at_depth, leading) = tissues.utilization_at(current_depth_fsw, thal_params);
            let (surface_util, _) = tissues.utilization_at(0.0, thal_params);

            // TTS and NDL
            let pp = ThalmannPlanParams {
                fo2: current_fo2,
                fhe: current_fhe,
                surface_p,
                ascent_rate_m_min: ascent_rate,
                last_stop_depth,
                stop_interval,
                thal_params,
            };

            let (tts_sec, ndl_sec) = if ceiling_m > 0.0 {
                let tts = compute_tts_thalmann(&tissues, current_depth_m, &pp);
                (tts, 0)
            } else {
                let ndl = compute_ndl_thalmann(&tissues, current_depth_m, &pp);
                (0, ndl)
            };

            // Track maxima
            let ceil_f32 = ceiling_m as f32;
            let gf99_f32 = util_at_depth as f32;
            if ceil_f32 > max_ceiling_m {
                max_ceiling_m = ceil_f32;
            }
            if gf99_f32 > max_gf99 {
                max_gf99 = gf99_f32;
            }
            if tts_sec > max_tts_sec {
                max_tts_sec = tts_sec;
            }

            points.push(DecoSimPoint {
                t_sec: sample.t_sec,
                depth_m: sample.depth_m,
                ceiling_m: ceil_f32,
                gf99: gf99_f32,
                surface_gf: surface_util as f32,
                tts_sec,
                leading_compartment: leading as u8,
                ndl_sec,
            });
        }

        // Deco stop planning from final state
        let (deco_stops, truncated) = if params.plan_ascent {
            let last_sample = params.samples.last().unwrap();
            let current_depth_m = (last_sample.depth_m as f64).max(0.0);
            let pp = ThalmannPlanParams {
                fo2: current_fo2,
                fhe: current_fhe,
                surface_p,
                ascent_rate_m_min: ascent_rate,
                last_stop_depth,
                stop_interval,
                thal_params,
            };
            plan_deco_stops_thalmann(&tissues, current_depth_m, &pp)
        } else {
            (Vec::new(), false)
        };

        let total_deco_time_sec: i32 = deco_stops.iter().map(|s| s.duration_sec).sum();

        Ok(DecoSimResult {
            points,
            deco_stops,
            total_deco_time_sec,
            max_ceiling_m,
            max_gf99,
            max_tts_sec,
            model: DecoModel::ThalmannElDca,
            truncated,
        })
    }
}

// ============================================================================
// Tissue State
// ============================================================================

/// Thalmann tissue compartment state.
///
/// All pressures stored in fsw to match NEDU reference code. Conversion
/// to/from bar/metres happens at the engine boundary.
#[derive(Debug, Clone)]
struct ThalmannTissueState {
    /// Inert gas tension per compartment (fsw).
    p_ig: Vec<f64>,
}

impl ThalmannTissueState {
    /// Initialise all compartments at surface air equilibrium.
    ///
    /// Uses the provided surface pressure (in bar) for altitude-aware
    /// initialisation. Falls back to sea-level 33 fsw if not specified.
    fn surface_equilibrium(surface_pressure_bar: f64, params: &ThalmannParamSet) -> Self {
        let surface_fsw = bar_to_fsw(surface_pressure_bar);
        let f_inert_air = 1.0 - AIR_FO2; // ~0.7905 (N2 + trace gases)
        let p_surface = (surface_fsw - PACO2_FSW) * f_inert_air;
        Self {
            p_ig: vec![p_surface; params.num_compartments],
        }
    }

    /// Update all compartments for a time interval using E-L kinetics.
    ///
    /// # Arguments
    /// - `dt_sec` — time interval in seconds
    /// - `p_inspired_fsw` — inspired inert gas partial pressure (fsw)
    /// - `p_ambient_fsw` — ambient pressure (fsw), used for crossover check
    /// - `r_inspired` — rate of change of inspired PP (fsw/sec), for linear term
    /// - `r_ambient` — rate of change of ambient pressure (fsw/sec), for linear term
    /// - `params` — parameter set
    fn update(
        &mut self,
        dt_sec: f64,
        p_inspired_fsw: f64,
        p_ambient_fsw: f64,
        r_inspired: f64,
        r_ambient: f64,
        params: &ThalmannParamSet,
    ) {
        if dt_sec <= 0.0 {
            return;
        }

        for i in 0..params.num_compartments {
            let is_offgas = self.p_ig[i] > p_inspired_fsw;

            // Select half-time: apply SDR for off-gassing
            let ht_min = if is_offgas {
                params.half_times_min[i] / params.sdr[i]
            } else {
                params.half_times_min[i]
            };

            // Check crossover condition (off-gassing only):
            // Linear washout when P_amb < p_ig + P_FVG - PBOVP
            let use_linear =
                is_offgas && p_ambient_fsw < self.p_ig[i] + P_FVG_FSW - params.pbovp_fsw;

            if use_linear {
                // Linear washout (Eq 10 from TR 18-05)
                let k = 2.0_f64.ln() / (ht_min * 60.0);
                // Isobaric term: driving force is (P_a - P_amb + P_FVG - PBOVP)
                let driving_force = p_inspired_fsw - p_ambient_fsw + P_FVG_FSW - params.pbovp_fsw;
                let linear_change = driving_force * dt_sec * k;
                // Depth-change correction term: (r_inspired - r_ambient) * t^2/2 * k
                let depth_change_correction = (r_inspired - r_ambient) * dt_sec * dt_sec / 2.0 * k;
                self.p_ig[i] += linear_change + depth_change_correction;
            } else {
                // Exponential (Schreiner equation)
                self.p_ig[i] = schreiner_step(self.p_ig[i], p_inspired_fsw, ht_min, dt_sec);
            }
        }
    }

    /// Compute the ceiling depth in fsw using MPTT tables.
    ///
    /// For each compartment: D_i = (p_ig[i] - M0[i]) / beta1[i].
    /// The ceiling is the maximum across all compartments (clamped to >= 0).
    fn ceiling_fsw(&self, params: &ThalmannParamSet) -> f64 {
        let mut max_ceil: f64 = 0.0;
        for i in 0..params.num_compartments {
            let d_i = (self.p_ig[i] - params.m0_fsw[i]) / params.beta1[i];
            if d_i > max_ceil {
                max_ceil = d_i;
            }
        }
        max_ceil
    }

    /// Compute MPTT utilization at a given depth.
    ///
    /// Returns (utilization_percent, leading_compartment_index).
    /// Utilization = p_ig[i] / M_i(D) * 100, where M_i(D) = M0[i] + beta1[i] * D.
    fn utilization_at(&self, depth_fsw: f64, params: &ThalmannParamSet) -> (f64, usize) {
        let mut max_util: f64 = 0.0;
        let mut leading: usize = 0;
        for i in 0..params.num_compartments {
            let m_at_d = params.m0_fsw[i] + params.beta1[i] * depth_fsw;
            if m_at_d > 1e-10 {
                let util = self.p_ig[i] / m_at_d * 100.0;
                if util > max_util {
                    max_util = util;
                    leading = i;
                }
            }
        }
        (max_util, leading)
    }
}

// ============================================================================
// Helper: round up to stop interval (shared with Bühlmann)
// ============================================================================

fn round_up_to_stop(depth_m: f64, stop_interval: f64) -> f64 {
    if depth_m <= 0.0 {
        return 0.0;
    }
    (depth_m / stop_interval).ceil() * stop_interval
}

// ============================================================================
// Planner Parameters
// ============================================================================

struct ThalmannPlanParams<'a> {
    fo2: f64,
    fhe: f64,
    surface_p: f64,
    ascent_rate_m_min: f64,
    last_stop_depth: f64,
    stop_interval: f64,
    thal_params: &'a ThalmannParamSet,
}

// ============================================================================
// TTS Computation
// ============================================================================

fn compute_tts_thalmann(
    tissues: &ThalmannTissueState,
    current_depth_m: f64,
    pp: &ThalmannPlanParams,
) -> i32 {
    let (stops, _) = plan_deco_stops_thalmann(tissues, current_depth_m, pp);

    let mut total_sec = 0.0;
    let mut depth = current_depth_m;

    for stop in &stops {
        let travel_m = depth - stop.depth_m as f64;
        if travel_m > 0.0 {
            total_sec += (travel_m / pp.ascent_rate_m_min) * 60.0;
        }
        total_sec += stop.duration_sec as f64;
        depth = stop.depth_m as f64;
    }

    // Final ascent to surface
    if depth > 0.0 {
        total_sec += (depth / pp.ascent_rate_m_min) * 60.0;
    }

    total_sec.ceil() as i32
}

// ============================================================================
// NDL Computation
// ============================================================================

fn compute_ndl_thalmann(
    tissues: &ThalmannTissueState,
    current_depth_m: f64,
    pp: &ThalmannPlanParams,
) -> i32 {
    if current_depth_m <= 0.0 {
        return 0;
    }

    let ambient_p = depth_to_pressure(current_depth_m, pp.surface_p);
    let ambient_fsw = bar_to_fsw(ambient_p);
    let (fn2, fhe) = inspired_fractions(pp.fo2, pp.fhe, None, ambient_p);
    let f_inert = fn2 + fhe;
    let p_inspired_fsw = (ambient_fsw - PACO2_FSW) * f_inert;

    // Binary search for NDL
    let mut lo: f64 = 0.0;
    let mut hi: f64 = 60.0;
    let max_time = 12000.0; // 200 min

    // Phase 1: double time until ceiling appears
    while hi < max_time {
        let mut trial = tissues.clone();
        // At constant depth: r_inspired = 0, r_ambient = 0
        trial.update(hi, p_inspired_fsw, ambient_fsw, 0.0, 0.0, pp.thal_params);
        let ceil = trial.ceiling_fsw(pp.thal_params);
        if ceil > 0.0 {
            break;
        }
        lo = hi;
        hi *= 2.0;
    }

    if hi >= max_time {
        let mut trial = tissues.clone();
        trial.update(
            max_time,
            p_inspired_fsw,
            ambient_fsw,
            0.0,
            0.0,
            pp.thal_params,
        );
        let ceil = trial.ceiling_fsw(pp.thal_params);
        if ceil <= 0.0 {
            return max_time as i32;
        }
        hi = max_time;
    }

    // Phase 2: bisect to ±5 sec
    while (hi - lo) > 5.0 {
        let mid = (lo + hi) / 2.0;
        let mut trial = tissues.clone();
        trial.update(mid, p_inspired_fsw, ambient_fsw, 0.0, 0.0, pp.thal_params);
        let ceil = trial.ceiling_fsw(pp.thal_params);
        if ceil > 0.0 {
            hi = mid;
        } else {
            lo = mid;
        }
    }

    lo as i32
}

// ============================================================================
// Deco Stop Planner
// ============================================================================

fn plan_deco_stops_thalmann(
    tissues: &ThalmannTissueState,
    current_depth_m: f64,
    pp: &ThalmannPlanParams,
) -> (Vec<DecoStop>, bool) {
    let mut tissues = tissues.clone();
    let mut stops = Vec::new();
    let mut depth = current_depth_m;
    let mut truncated = false;

    // Determine first stop from ceiling
    let ceiling_fsw = tissues.ceiling_fsw(pp.thal_params);
    let ceiling_m = fsw_to_meters(ceiling_fsw.max(0.0));
    let mut stop_depth = round_up_to_stop(ceiling_m, pp.stop_interval);

    if stop_depth > 0.0 && stop_depth < pp.last_stop_depth {
        stop_depth = pp.last_stop_depth;
    }

    if stop_depth <= 0.0 {
        return (stops, false);
    }

    // Ascend to first stop
    ascend_to_thalmann(&mut tissues, &mut depth, stop_depth, pp);

    // Process stops
    let mut current_stop = stop_depth;
    let max_total_stop_time = 36000.0; // 10 hour safety limit

    while current_stop >= pp.last_stop_depth {
        let next_stop = if current_stop > pp.last_stop_depth {
            (current_stop - pp.stop_interval).max(pp.last_stop_depth)
        } else {
            0.0
        };

        let mut stop_time_sec: f64 = 0.0;

        // Simulate 1-minute increments until ceiling clears to next stop
        loop {
            let ceil_fsw = tissues.ceiling_fsw(pp.thal_params);
            let ceil_m = fsw_to_meters(ceil_fsw.max(0.0));

            if ceil_m <= next_stop {
                break;
            }

            // Wait 60 seconds at this stop
            let ambient_p = depth_to_pressure(current_stop, pp.surface_p);
            let ambient_fsw = bar_to_fsw(ambient_p);
            let (fn2, fhe) = inspired_fractions(pp.fo2, pp.fhe, None, ambient_p);
            let f_inert = fn2 + fhe;
            let p_inspired_fsw = (ambient_fsw - PACO2_FSW) * f_inert;

            tissues.update(60.0, p_inspired_fsw, ambient_fsw, 0.0, 0.0, pp.thal_params);
            stop_time_sec += 60.0;

            if stop_time_sec > max_total_stop_time {
                truncated = true;
                break;
            }
        }

        if stop_time_sec > 0.0 {
            stops.push(DecoStop {
                depth_m: current_stop as f32,
                duration_sec: stop_time_sec as i32,
                gas_mix_index: -1,
            });
        }

        if current_stop <= pp.last_stop_depth {
            break;
        }

        ascend_to_thalmann(&mut tissues, &mut depth, next_stop, pp);
        current_stop = next_stop;
    }

    (stops, truncated)
}

/// Simulate ascent between two depths, updating tissue state during travel.
fn ascend_to_thalmann(
    tissues: &mut ThalmannTissueState,
    current_depth: &mut f64,
    target_depth: f64,
    pp: &ThalmannPlanParams,
) {
    let travel_m = *current_depth - target_depth;
    if travel_m <= 0.0 {
        *current_depth = target_depth;
        return;
    }

    let travel_sec = (travel_m / pp.ascent_rate_m_min) * 60.0;
    let avg_depth = (*current_depth + target_depth) / 2.0;
    let ambient_p = depth_to_pressure(avg_depth, pp.surface_p);
    let ambient_fsw = bar_to_fsw(ambient_p);

    let (fn2, fhe_frac) = inspired_fractions(pp.fo2, pp.fhe, None, ambient_p);
    let f_inert = fn2 + fhe_frac;
    let p_inspired_fsw = (ambient_fsw - PACO2_FSW) * f_inert;

    // Compute rates for depth change
    let start_fsw = meters_to_fsw(*current_depth);
    let end_fsw = meters_to_fsw(target_depth);
    let r_ambient = if travel_sec > 0.0 {
        (end_fsw - start_fsw) / travel_sec
    } else {
        0.0
    };
    let r_inspired = r_ambient * f_inert;

    tissues.update(
        travel_sec,
        p_inspired_fsw,
        ambient_fsw,
        r_inspired,
        r_ambient,
        pp.thal_params,
    );
    *current_depth = target_depth;
}

// ============================================================================
// Tests
// ============================================================================

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

    fn sample_with_gas(t_sec: i32, depth_m: f32, gas_idx: i32) -> SampleInput {
        SampleInput {
            gasmix_index: Some(gas_idx),
            ..sample(t_sec, depth_m)
        }
    }

    fn default_params(samples: Vec<SampleInput>) -> DecoSimParams {
        DecoSimParams {
            model: DecoModel::ThalmannElDca,
            samples,
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: None,
            last_stop_depth_m: None,
            stop_interval_m: None,
            gf_low: None,
            gf_high: None,
            plan_ascent: false,
        }
    }

    // ── E-L Kinetics Tests ──────────────────────────────────────────────

    #[test]
    fn test_exponential_ongassing_matches_schreiner() {
        let params = &XVAL_HE_9_023;
        let mut tissues =
            ThalmannTissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE, params);
        let initial = tissues.p_ig[0];

        // On-gassing at high pressure — should be purely exponential
        let p_inspired = 100.0; // fsw — higher than tissue, so on-gassing
        let ambient = 133.0; // fsw — 100 fsw depth (133 = 33 + 100)
        let dt = 300.0; // 5 minutes

        tissues.update(dt, p_inspired, ambient, 0.0, 0.0, params);

        // Compare with direct Schreiner step using on-gas half-time
        let expected = schreiner_step(initial, p_inspired, params.half_times_min[0], dt);
        assert!(
            (tissues.p_ig[0] - expected).abs() < 1e-10,
            "On-gassing should match Schreiner: got {}, expected {}",
            tissues.p_ig[0],
            expected
        );
    }

    #[test]
    fn test_sdr_2_faster_washout_than_sdr_1() {
        let mut state_sdr1 = ThalmannTissueState { p_ig: vec![80.0] };
        let mut state_sdr2 = ThalmannTissueState { p_ig: vec![80.0] };

        // Parameters: same base HT=20, but SDR=1 vs SDR=2
        let params_sdr1 = ThalmannParamSet {
            num_compartments: 1,
            half_times_min: &[20.0],
            sdr: &[1.0],
            m0_fsw: &[85.0],
            beta1: &[1.0],
            pbovp_fsw: 0.0,
        };
        let params_sdr2 = ThalmannParamSet {
            num_compartments: 1,
            half_times_min: &[20.0],
            sdr: &[2.0],
            m0_fsw: &[85.0],
            beta1: &[1.0],
            pbovp_fsw: 0.0,
        };

        // Off-gassing: tissue at 80 fsw, inspired at 25 fsw, ambient at 33 fsw
        // Both should be exponential (ambient=33, p_ig=80, P_FVG=4.3 → 33 < 80+4.3=84.3 → linear)
        // Actually this triggers linear too. Let's use ambient >> p_ig to force exponential.
        // For pure exponential off-gassing, we need ambient >= p_ig + P_FVG.
        // p_ig=80, P_FVG=4.3, so we need ambient >= 84.3.
        // That means tissue is NOT supersaturated, so it's actually on-gassing...
        // The crossover only applies to off-gassing. Off-gassing = p_ig > p_inspired.
        // So p_inspired=25, p_ig=80, ambient=33: off-gassing AND 33 < 80+4.3 → linear.
        // For exponential off-gassing: ambient >= p_ig + P_FVG = 84.3.
        // But at ambient=84.3, p_inspired would be (84.3-1.5)*f_inert ≈ 65.4 which is < 80, still off-gassing.
        // And ambient=84.3 >= 80+4.3, so NO linear → exponential.
        // But SDR still applies to exponential off-gassing!
        let p_insp = 65.0; // < 80, so off-gassing
        let p_amb = 90.0; // >= 80 + 4.3, so exponential mode
        let dt = 600.0; // 10 minutes

        state_sdr1.update(dt, p_insp, p_amb, 0.0, 0.0, &params_sdr1);
        state_sdr2.update(dt, p_insp, p_amb, 0.0, 0.0, &params_sdr2);

        // SDR=2 should wash out faster (lower tissue tension after off-gassing)
        assert!(
            state_sdr2.p_ig[0] < state_sdr1.p_ig[0],
            "SDR=2 ({}) should produce lower tension than SDR=1 ({})",
            state_sdr2.p_ig[0],
            state_sdr1.p_ig[0]
        );
    }

    #[test]
    fn test_linear_crossover_activates() {
        let params = &ThalmannParamSet {
            num_compartments: 1,
            half_times_min: &[20.0],
            sdr: &[1.0],
            m0_fsw: &[85.0],
            beta1: &[1.0],
            pbovp_fsw: 0.0,
        };

        let initial_tension = 80.0;
        let p_inspired = 25.0;
        let p_ambient = 33.0; // surface: 33 < 80 + 4.3 - 0 = 84.3 → linear
        let dt = 300.0;

        let mut tissues_linear = ThalmannTissueState {
            p_ig: vec![initial_tension],
        };
        tissues_linear.update(dt, p_inspired, p_ambient, 0.0, 0.0, params);

        // Compare with pure exponential (what Schreiner would give with SDR=1 off-gas HT)
        let expected_exp = schreiner_step(initial_tension, p_inspired, 20.0, dt);

        // Linear washout should produce a DIFFERENT result than pure exponential
        assert!(
            (tissues_linear.p_ig[0] - expected_exp).abs() > 0.01,
            "Linear crossover should differ from exponential: linear={}, exp={}",
            tissues_linear.p_ig[0],
            expected_exp
        );
    }

    #[test]
    fn test_linear_washout_slower_than_exponential() {
        // The linear model constrains washout rate, so tissue tension should be
        // HIGHER (slower washout) than pure exponential at surface.
        let params = &ThalmannParamSet {
            num_compartments: 1,
            half_times_min: &[20.0],
            sdr: &[1.0],
            m0_fsw: &[85.0],
            beta1: &[1.0],
            pbovp_fsw: 0.0,
        };

        let initial_tension = 80.0;
        let p_inspired = 25.0;
        let p_ambient = 33.0; // triggers linear
        let dt = 600.0; // 10 minutes

        let mut tissues = ThalmannTissueState {
            p_ig: vec![initial_tension],
        };
        tissues.update(dt, p_inspired, p_ambient, 0.0, 0.0, params);

        let pure_exp = schreiner_step(initial_tension, p_inspired, 20.0, dt);

        // Linear washout should be slower → higher remaining tension
        assert!(
            tissues.p_ig[0] > pure_exp,
            "Linear washout ({}) should be slower (higher tension) than exponential ({})",
            tissues.p_ig[0],
            pure_exp
        );
    }

    // ── MPTT Ceiling Tests ──────────────────────────────────────────────

    #[test]
    fn test_ceiling_from_known_tensions() {
        let params = &XVAL_HE_9_023;
        // Set compartment 0 to 118 fsw: ceiling = (118 - 85) / 1.0 = 33 fsw
        let tissues = ThalmannTissueState {
            p_ig: vec![118.0, 30.0, 30.0, 30.0, 30.0],
        };
        let ceil = tissues.ceiling_fsw(params);
        assert!(
            (ceil - 33.0).abs() < 1e-10,
            "Ceiling should be 33 fsw, got {ceil}"
        );
    }

    #[test]
    fn test_zero_ceiling_at_equilibrium() {
        let params = &XVAL_HE_9_023;
        let tissues = ThalmannTissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE, params);
        let ceil = tissues.ceiling_fsw(params);
        assert!(
            ceil <= 0.0,
            "Surface equilibrium should have zero ceiling, got {ceil}"
        );
    }

    #[test]
    fn test_utilization_at_depth() {
        let params = &XVAL_HE_9_023;
        // Compartment 0: p_ig = 85, M0 = 85, beta1 = 1.0
        // At surface (D=0): M = 85, util = 85/85 * 100 = 100%
        // At 33 fsw (D=33): M = 85 + 1.0*33 = 118, util = 85/118 * 100 ≈ 72%
        let tissues = ThalmannTissueState {
            p_ig: vec![85.0, 30.0, 30.0, 30.0, 30.0],
        };

        let (surface_util, _) = tissues.utilization_at(0.0, params);
        assert!(
            (surface_util - 100.0).abs() < 0.1,
            "Surface util should be ~100%, got {surface_util}"
        );

        let (depth_util, _) = tissues.utilization_at(33.0, params);
        let expected = 85.0 / 118.0 * 100.0;
        assert!(
            (depth_util - expected).abs() < 0.1,
            "Depth util should be ~{expected}%, got {depth_util}"
        );
    }

    // ── Integration Tests via simulate() ────────────────────────────────

    #[test]
    fn test_empty_samples_error() {
        let params = default_params(vec![]);
        let result = ThalmannEngine.simulate(&params);
        assert!(matches!(result, Err(DecoSimError::EmptySamples { .. })));
    }

    #[test]
    fn test_model_field() {
        let params = default_params(vec![sample(0, 0.0), sample(600, 10.0)]);
        let result = ThalmannEngine.simulate(&params).unwrap();
        assert_eq!(result.model, DecoModel::ThalmannElDca);
    }

    #[test]
    fn test_shallow_no_deco_dive() {
        // 10m for 10 min — should produce no ceiling
        let samples = vec![
            sample(0, 0.0),
            sample(60, 10.0),
            sample(600, 10.0),
            sample(660, 0.0),
        ];
        let result = ThalmannEngine.simulate(&default_params(samples)).unwrap();
        assert_eq!(result.points.len(), 4);
        for p in &result.points {
            assert!(
                p.ceiling_m <= 0.0,
                "Shallow dive should have no ceiling, got {} at t={}",
                p.ceiling_m,
                p.t_sec
            );
        }
    }

    #[test]
    fn test_deep_dive_produces_stops() {
        // 60m for 20 min with He-O2 mix (simulated as air for now)
        let samples = vec![
            sample(0, 0.0),
            sample(120, 60.0),  // descent
            sample(1200, 60.0), // bottom (20 min)
            sample(1320, 50.0), // start ascent
        ];
        let mut params = default_params(samples);
        params.plan_ascent = true;

        let result = ThalmannEngine.simulate(&params).unwrap();

        // Should have some ceiling at depth
        let max_ceil = result
            .points
            .iter()
            .map(|p| p.ceiling_m)
            .fold(0.0f32, f32::max);
        assert!(
            max_ceil > 0.0,
            "Deep dive should produce a ceiling, got max_ceil={max_ceil}"
        );

        // Should produce deco stops when plan_ascent is true
        assert!(
            !result.deco_stops.is_empty(),
            "Deep dive should produce deco stops"
        );

        // Total deco time should be positive
        assert!(
            result.total_deco_time_sec > 0,
            "Total deco time should be > 0"
        );
    }

    #[test]
    fn test_tts_increases_with_bottom_time() {
        // Compare 10 min vs 20 min at 40m
        let samples_short = vec![
            sample(0, 0.0),
            sample(60, 40.0),
            sample(600, 40.0), // 10 min bottom
        ];
        let samples_long = vec![
            sample(0, 0.0),
            sample(60, 40.0),
            sample(1200, 40.0), // 20 min bottom
        ];

        let result_short = ThalmannEngine
            .simulate(&default_params(samples_short))
            .unwrap();
        let result_long = ThalmannEngine
            .simulate(&default_params(samples_long))
            .unwrap();

        let tts_short = result_short.points.last().unwrap().tts_sec;
        let tts_long = result_long.points.last().unwrap().tts_sec;

        // Longer bottom time should produce >= TTS (or both 0 if no deco)
        assert!(
            tts_long >= tts_short,
            "Longer bottom time should produce more TTS: short={tts_short}, long={tts_long}"
        );
    }

    #[test]
    fn test_ndl_decreases_with_depth() {
        // Compare NDL at 15m vs 30m after same short bottom time
        let samples_shallow = vec![sample(0, 0.0), sample(30, 15.0), sample(120, 15.0)];
        let samples_deep = vec![sample(0, 0.0), sample(30, 30.0), sample(120, 30.0)];

        let result_shallow = ThalmannEngine
            .simulate(&default_params(samples_shallow))
            .unwrap();
        let result_deep = ThalmannEngine
            .simulate(&default_params(samples_deep))
            .unwrap();

        let ndl_shallow = result_shallow.points.last().unwrap().ndl_sec;
        let ndl_deep = result_deep.points.last().unwrap().ndl_sec;

        assert!(
            ndl_shallow >= ndl_deep,
            "Deeper dive should have shorter NDL: shallow={ndl_shallow}, deep={ndl_deep}"
        );
    }

    #[test]
    fn test_stops_at_interval_multiples() {
        let samples = vec![sample(0, 0.0), sample(120, 60.0), sample(1200, 60.0)];
        let mut params = default_params(samples);
        params.plan_ascent = true;
        params.stop_interval_m = Some(3.0);

        let result = ThalmannEngine.simulate(&params).unwrap();

        for stop in &result.deco_stops {
            let remainder = (stop.depth_m as f64) % 3.0;
            assert!(
                remainder.abs() < 0.01 || (3.0 - remainder).abs() < 0.01,
                "Stop at {}m is not a multiple of 3m",
                stop.depth_m
            );
            assert!(
                stop.duration_sec > 0,
                "Stop duration should be positive, got {}",
                stop.duration_sec
            );
        }
    }

    #[test]
    fn test_not_truncated_normal_profile() {
        let samples = vec![sample(0, 0.0), sample(60, 20.0), sample(600, 20.0)];
        let result = ThalmannEngine.simulate(&default_params(samples)).unwrap();
        assert!(!result.truncated, "Normal profile should not be truncated");
    }

    #[test]
    fn test_invalid_params() {
        let mut params = default_params(vec![sample(0, 0.0), sample(60, 10.0)]);
        params.ascent_rate_m_min = Some(-1.0);
        assert!(matches!(
            ThalmannEngine.simulate(&params),
            Err(DecoSimError::InvalidParam { .. })
        ));
    }

    #[test]
    fn test_gf_params_silently_ignored() {
        // GF params should not cause errors for Thalmann
        let mut params = default_params(vec![sample(0, 0.0), sample(600, 20.0)]);
        params.gf_low = Some(30);
        params.gf_high = Some(85);
        let result = ThalmannEngine.simulate(&params);
        assert!(result.is_ok(), "GF params should be silently ignored");
    }

    #[test]
    fn test_sanity_deco_ballpark() {
        // XVal-He-9_023 is calibrated for He-O2 diving. With air (N2),
        // the linear washout produces longer deco than Bühlmann because
        // the parameter set isn't optimised for N2. This test validates
        // the planner produces a finite, non-trivial deco schedule.
        let samples = vec![sample(0, 0.0), sample(120, 60.0), sample(1200, 60.0)];
        let mut params = default_params(samples);
        params.plan_ascent = true;

        let result = ThalmannEngine.simulate(&params).unwrap();

        let deco_min = result.total_deco_time_sec as f64 / 60.0;
        assert!(
            deco_min > 1.0 && deco_min < 600.0,
            "60m/20min deco should be 1-600 min, got {deco_min:.1} min"
        );
        assert!(!result.truncated, "Should not hit safety limit");
    }

    #[test]
    fn test_single_inert_gas_model() {
        // The current implementation uses a single combined inert gas
        // fraction (fn2 + fhe). He-O2 and air with the same total inert
        // fraction produce identical tissue loading — this is a known
        // limitation of the single-gas model (dual-gas is future work).
        let samples = vec![
            sample(0, 0.0),
            sample_with_gas(60, 40.0, 0),
            sample(1200, 40.0),
        ];

        let params_air = default_params(samples.clone());

        let mut params_he = default_params(samples);
        params_he.gas_mixes = vec![crate::buhlmann::GasMixInput {
            mix_index: 0,
            o2_fraction: 0.21,
            he_fraction: 0.79,
        }];

        let result_air = ThalmannEngine.simulate(&params_air).unwrap();
        let result_he = ThalmannEngine.simulate(&params_he).unwrap();

        // Same total inert fraction → same tissue loading → same results
        assert_eq!(result_air.max_tts_sec, result_he.max_tts_sec);
        assert_eq!(result_air.max_ceiling_m, result_he.max_ceiling_m);
    }

    #[test]
    fn test_different_fo2_produces_different_result() {
        // Different O2 fractions change the inert gas fraction and
        // should produce measurably different results.
        let samples = vec![
            sample(0, 0.0),
            sample_with_gas(60, 40.0, 0),
            sample(1200, 40.0),
        ];

        // Air (21% O2)
        let params_air = default_params(samples.clone());

        // EAN32 (32% O2, less inert gas)
        let mut params_ean32 = default_params(samples);
        params_ean32.gas_mixes = vec![crate::buhlmann::GasMixInput {
            mix_index: 0,
            o2_fraction: 0.32,
            he_fraction: 0.0,
        }];

        let result_air = ThalmannEngine.simulate(&params_air).unwrap();
        let result_ean32 = ThalmannEngine.simulate(&params_ean32).unwrap();

        // EAN32 has less inert gas → lower tissue loading → less deco
        let ceil_air = result_air.points.last().unwrap().ceiling_m;
        let ceil_ean32 = result_ean32.points.last().unwrap().ceiling_m;
        assert!(
            ceil_air >= ceil_ean32,
            "Air ({ceil_air}) should have >= ceiling than EAN32 ({ceil_ean32})"
        );
    }

    // ── Mutation-killing Tests ──────────────────────────────────────────

    #[test]
    fn test_tts_positive_for_deco_dive() {
        // Deep dive that requires deco — TTS must be > 1
        let samples = vec![sample(0, 0.0), sample(120, 60.0), sample(1200, 60.0)];
        let result = ThalmannEngine.simulate(&default_params(samples)).unwrap();
        let last = result.points.last().unwrap();
        assert!(
            last.tts_sec > 1,
            "TTS should be > 1 for 60m/20min dive, got {}",
            last.tts_sec
        );
    }

    #[test]
    fn test_ndl_positive_for_shallow_dive() {
        // Shallow dive — NDL must be > 1 (and not negative)
        let samples = vec![sample(0, 0.0), sample(60, 15.0), sample(120, 15.0)];
        let result = ThalmannEngine.simulate(&default_params(samples)).unwrap();
        let last = result.points.last().unwrap();
        assert!(
            last.ndl_sec > 1,
            "NDL should be > 1 for shallow dive, got {}",
            last.ndl_sec
        );
    }

    #[test]
    fn test_ceiling_with_beta1_not_one() {
        // Compartment 3 has beta1=2.0. When it's the controlling compartment,
        // ceiling = (p_ig - M0) / beta1 differs from (p_ig - M0) * beta1.
        let params = &XVAL_HE_9_023;
        // Set comp 3 (beta1=2.0, M0=41.731) to 91.731 fsw:
        //   ceiling = (91.731 - 41.731) / 2.0 = 25.0 fsw (correct)
        //   vs       (91.731 - 41.731) * 2.0 = 100.0 fsw (if / → *)
        let tissues = ThalmannTissueState {
            p_ig: vec![30.0, 30.0, 30.0, 91.731, 30.0],
        };
        let ceil = tissues.ceiling_fsw(params);
        let expected = (91.731 - 41.731) / 2.0; // 25.0
        assert!(
            (ceil - expected).abs() < 0.01,
            "Ceiling should be {expected} fsw (beta1=2.0), got {ceil}"
        );
    }

    #[test]
    fn test_round_up_to_stop_fractional() {
        // 7.5m should round up to 9.0m (next 3m multiple)
        let result = round_up_to_stop(7.5, 3.0);
        assert!(
            (result - 9.0).abs() < 0.01,
            "7.5m should round to 9.0m, got {result}"
        );

        // 6.0m should stay at 6.0m (already at stop)
        let result2 = round_up_to_stop(6.0, 3.0);
        assert!(
            (result2 - 6.0).abs() < 0.01,
            "6.0m should stay at 6.0m, got {result2}"
        );

        // 0.1m should round up to 3.0m
        let result3 = round_up_to_stop(0.1, 3.0);
        assert!(
            (result3 - 3.0).abs() < 0.01,
            "0.1m should round to 3.0m, got {result3}"
        );
    }

    #[test]
    fn test_altitude_surface_pressure() {
        // At altitude (e.g., 2000m, ~0.80 bar), initial tissue tension should
        // be lower than at sea level (1.01325 bar).
        let params = &XVAL_HE_9_023;
        let sea_level = ThalmannTissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE, params);
        let altitude = ThalmannTissueState::surface_equilibrium(0.80, params);

        assert!(
            altitude.p_ig[0] < sea_level.p_ig[0],
            "Altitude tissue ({}) should be lower than sea level ({})",
            altitude.p_ig[0],
            sea_level.p_ig[0]
        );
    }

    #[test]
    fn test_altitude_produces_different_result() {
        // Same dive profile at altitude should produce different deco output
        let samples = vec![sample(0, 0.0), sample(60, 30.0), sample(1200, 30.0)];
        let mut sea_params = default_params(samples.clone());
        sea_params.surface_pressure_bar = Some(1.01325);

        let mut alt_params = default_params(samples);
        alt_params.surface_pressure_bar = Some(0.80); // ~2000m altitude

        let sea_result = ThalmannEngine.simulate(&sea_params).unwrap();
        let alt_result = ThalmannEngine.simulate(&alt_params).unwrap();

        // At altitude, effective depth is greater → more loading → higher ceiling
        let sea_ceil = sea_result.points.last().unwrap().ceiling_m;
        let alt_ceil = alt_result.points.last().unwrap().ceiling_m;
        assert!(
            alt_ceil >= sea_ceil,
            "Altitude ceiling ({alt_ceil}) should be >= sea level ({sea_ceil})"
        );
    }

    #[test]
    fn test_param_validation_sdr_zero() {
        let bad_params = ThalmannParamSet {
            num_compartments: 1,
            half_times_min: &[10.0],
            sdr: &[0.0], // invalid!
            m0_fsw: &[85.0],
            beta1: &[1.0],
            pbovp_fsw: 0.0,
        };
        assert!(bad_params.validate().is_err());
    }

    #[test]
    fn test_param_validation_beta1_zero() {
        let bad_params = ThalmannParamSet {
            num_compartments: 1,
            half_times_min: &[10.0],
            sdr: &[1.0],
            m0_fsw: &[85.0],
            beta1: &[0.0], // invalid!
            pbovp_fsw: 0.0,
        };
        assert!(bad_params.validate().is_err());
    }

    #[test]
    fn test_param_validation_length_mismatch() {
        let bad_params = ThalmannParamSet {
            num_compartments: 2,
            half_times_min: &[10.0], // only 1 element, need 2
            sdr: &[1.0, 1.0],
            m0_fsw: &[85.0, 64.0],
            beta1: &[1.0, 1.0],
            pbovp_fsw: 0.0,
        };
        assert!(bad_params.validate().is_err());
    }
}
