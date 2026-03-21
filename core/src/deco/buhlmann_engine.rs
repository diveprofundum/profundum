//! Bühlmann ZHL-16C decompression engine with gradient factor support.
//!
//! Computes ceilings, GF99, SurfGF, TTS, NDL, and deco stop schedules
//! using the Baker gradient factor method for conservatism adjustment.

use super::shared::*;
use super::types::*;
use crate::buhlmann::{A_HE, A_N2, B_HE, B_N2, HE_HALF_TIMES, N2_HALF_TIMES, NUM_COMPARTMENTS};

// ============================================================================
// Bühlmann Engine
// ============================================================================

pub(crate) struct BuhlmannEngine;

impl BuhlmannEngine {
    pub(crate) fn simulate(&self, params: &DecoSimParams) -> Result<DecoSimResult, DecoSimError> {
        // Validate inputs
        if params.samples.is_empty() {
            return Err(DecoSimError::EmptySamples {
                msg: "No samples provided".to_string(),
            });
        }

        let gf_low_pct = params.gf_low.unwrap_or(100);
        let gf_high_pct = params.gf_high.unwrap_or(100);
        if gf_low_pct > gf_high_pct {
            return Err(DecoSimError::InvalidParam {
                msg: format!("gf_low ({gf_low_pct}) must be <= gf_high ({gf_high_pct})"),
            });
        }
        if gf_low_pct == 0 || gf_high_pct == 0 {
            return Err(DecoSimError::InvalidParam {
                msg: "Gradient factors must be > 0".to_string(),
            });
        }

        let gf_low = gf_low_pct as f64 / 100.0;
        let gf_high = gf_high_pct as f64 / 100.0;
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

        // Build gas mix lookup
        let mut gas_lookup: std::collections::HashMap<i32, (f64, f64)> =
            std::collections::HashMap::new();
        for mix in &params.gas_mixes {
            gas_lookup.insert(mix.mix_index, (mix.o2_fraction, mix.he_fraction));
        }
        let default_gas = gas_lookup.get(&0).copied().unwrap_or((AIR_FO2, 0.0));
        let mut current_fo2 = default_gas.0;
        let mut current_fhe = default_gas.1;

        let mut tissues = EngineTissueState::surface_equilibrium(surface_p);
        let mut points = Vec::with_capacity(params.samples.len());
        let mut max_ceiling_m: f32 = 0.0;
        let mut max_gf99: f32 = 0.0;
        let mut max_tts_sec: i32 = 0;

        // Track first stop depth for GF interpolation
        let mut first_stop_depth_m: Option<f64> = None;

        for (idx, sample) in params.samples.iter().enumerate() {
            // Update tissues for time interval
            if idx > 0 {
                let dt_sec = (sample.t_sec - params.samples[idx - 1].t_sec) as f64;
                let avg_depth_m =
                    ((params.samples[idx - 1].depth_m as f64 + sample.depth_m as f64) / 2.0)
                        .max(0.0);
                let ambient_p = depth_to_pressure(avg_depth_m, surface_p);

                let (fn2, fhe) = inspired_fractions(
                    current_fo2,
                    current_fhe,
                    params.samples[idx - 1].ppo2.map(|v| v as f64),
                    ambient_p,
                );

                let p_inspired_n2 = (ambient_p - P_WATER_VAPOR) * fn2;
                let p_inspired_he = (ambient_p - P_WATER_VAPOR) * fhe;
                tissues.update(dt_sec, p_inspired_n2, p_inspired_he);
            }

            // Gas switch
            if let Some(mix_idx) = sample.gasmix_index {
                if let Some(&(fo2, fhe)) = gas_lookup.get(&mix_idx) {
                    current_fo2 = fo2;
                    current_fhe = fhe;
                }
            }

            let current_depth_m = (sample.depth_m as f64).max(0.0);
            let current_ambient_p = depth_to_pressure(current_depth_m, surface_p);

            // Compute GF-adjusted ceiling
            let raw_ceiling_p = tissues.gf_ceiling(gf_low, gf_high, first_stop_depth_m, surface_p);
            let ceiling_depth_m = pressure_to_depth(raw_ceiling_p, surface_p);
            let ceiling_m = round_up_to_stop(ceiling_depth_m, stop_interval);

            // Track first stop depth
            if ceiling_m > 0.0 && first_stop_depth_m.is_none() {
                first_stop_depth_m = Some(ceiling_m);
            }

            // GF99 and SurfGF
            let gf99 = tissues.max_gf_at_pressure(current_ambient_p);
            let (surface_gf, leading) = tissues.surface_gf_and_leading(surface_p);

            // TTS and NDL
            let pp = PlanParams::from_engine(
                &gas_lookup,
                sample.gasmix_index.unwrap_or(0),
                sample.ppo2.map(|v| v as f64),
                surface_p,
                ascent_rate,
                last_stop_depth,
                stop_interval,
                gf_low,
                gf_high,
                first_stop_depth_m,
            );
            let (tts_sec, ndl_sec) = if ceiling_m > 0.0 {
                let tts = compute_tts(&tissues, current_depth_m, &pp);
                (tts, 0)
            } else {
                let gas = pp.gas_at_depth(current_depth_m);
                let ndl = compute_ndl(
                    &tissues,
                    current_depth_m,
                    gas.fo2,
                    gas.fhe,
                    pp.ppo2,
                    surface_p,
                    gf_low,
                    gf_high,
                );
                (0, ndl)
            };

            // Track maxima
            let ceil_f32 = ceiling_m as f32;
            let gf99_f32 = gf99 as f32;
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
                surface_gf: surface_gf as f32,
                tts_sec,
                leading_compartment: leading as u8,
                ndl_sec,
            });
        }

        // Deco stop planning from final state
        let (deco_stops, truncated) = if params.plan_ascent {
            let last_sample = params.samples.last().unwrap();
            let current_depth_m = (last_sample.depth_m as f64).max(0.0);
            let pp = PlanParams::from_engine(
                &gas_lookup,
                last_sample.gasmix_index.unwrap_or(0),
                last_sample.ppo2.map(|v| v as f64),
                surface_p,
                ascent_rate,
                last_stop_depth,
                stop_interval,
                gf_low,
                gf_high,
                first_stop_depth_m,
            );
            plan_deco_stops(&tissues, current_depth_m, &pp)
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
            model: DecoModel::BuhlmannZhl16c,
            truncated,
        })
    }
}

// ============================================================================
// Internal Tissue State (extends buhlmann.rs TissueState with ceiling logic)
// ============================================================================

/// Internal tissue state with ceiling/stop computation methods.
///
/// This is a separate type from buhlmann::TissueState to avoid coupling
/// the existing SurfGF API to the new deco engine types.
#[derive(Debug, Clone)]
pub(crate) struct EngineTissueState {
    p_n2: [f64; NUM_COMPARTMENTS],
    p_he: [f64; NUM_COMPARTMENTS],
}

impl EngineTissueState {
    /// Initialise tissues at surface equilibrium (breathing air).
    pub(crate) fn surface_equilibrium(surface_pressure: f64) -> Self {
        let p_n2_surface = (surface_pressure - P_WATER_VAPOR) * AIR_FN2;
        let mut state = Self {
            p_n2: [0.0; NUM_COMPARTMENTS],
            p_he: [0.0; NUM_COMPARTMENTS],
        };
        for i in 0..NUM_COMPARTMENTS {
            state.p_n2[i] = p_n2_surface;
        }
        state
    }

    /// Update all compartments for a time interval using the Schreiner equation.
    pub(crate) fn update(&mut self, dt_sec: f64, p_inspired_n2: f64, p_inspired_he: f64) {
        if dt_sec <= 0.0 {
            return;
        }
        for i in 0..NUM_COMPARTMENTS {
            self.p_n2[i] = schreiner_step(self.p_n2[i], p_inspired_n2, N2_HALF_TIMES[i], dt_sec);
            self.p_he[i] = schreiner_step(self.p_he[i], p_inspired_he, HE_HALF_TIMES[i], dt_sec);
        }
    }

    /// Weighted a, b coefficients for compartment i.
    fn weighted_ab(&self, i: usize) -> (f64, f64) {
        let p_total = self.p_n2[i] + self.p_he[i];
        if p_total > 1e-10 {
            let a = (A_N2[i] * self.p_n2[i] + A_HE[i] * self.p_he[i]) / p_total;
            let b = (B_N2[i] * self.p_n2[i] + B_HE[i] * self.p_he[i]) / p_total;
            (a, b)
        } else {
            (A_N2[i], B_N2[i])
        }
    }

    /// Gradient factor for a single compartment at the given ambient pressure.
    fn compartment_gf(&self, i: usize, ambient_pressure: f64) -> f64 {
        let p_total = self.p_n2[i] + self.p_he[i];
        let (a, b) = self.weighted_ab(i);
        let m_value = a + ambient_pressure / b;
        let denom = m_value - ambient_pressure;
        if denom > 1e-10 {
            ((p_total - ambient_pressure) / denom) * 100.0
        } else {
            0.0
        }
    }

    /// Maximum gradient factor across all compartments at a given ambient pressure.
    fn max_gf_at_pressure(&self, ambient_pressure: f64) -> f64 {
        (0..NUM_COMPARTMENTS)
            .map(|i| self.compartment_gf(i, ambient_pressure))
            .fold(0.0_f64, f64::max)
    }

    /// SurfGF and leading compartment index.
    fn surface_gf_and_leading(&self, surface_pressure: f64) -> (f64, usize) {
        let mut max_gf: f64 = 0.0;
        let mut leading: usize = 0;
        for i in 0..NUM_COMPARTMENTS {
            let gf = self.compartment_gf(i, surface_pressure);
            if gf > max_gf {
                max_gf = gf;
                leading = i;
            }
        }
        (max_gf, leading)
    }

    /// GF-adjusted ceiling pressure across all compartments.
    ///
    /// Uses Baker GF interpolation: gf varies linearly from gf_low at the
    /// first stop depth to gf_high at the surface.
    ///
    /// Returns the maximum compartment ceiling as an absolute pressure (bar).
    fn gf_ceiling(
        &self,
        gf_low: f64,
        gf_high: f64,
        first_stop_depth_m: Option<f64>,
        surface_pressure: f64,
    ) -> f64 {
        // Determine GF at current ceiling depth (Baker interpolation).
        // If no first stop yet, use gf_low (we're finding where ceiling starts).
        let gf = if let Some(first_stop) = first_stop_depth_m {
            // Iterative: compute ceiling with current GF estimate, then refine.
            // One pass is sufficient for practical accuracy.
            let raw_max_ceil = self.raw_gf_ceiling_at(gf_low, surface_pressure);
            let ceil_depth = pressure_to_depth(raw_max_ceil, surface_pressure);
            gf_at_depth(ceil_depth, first_stop, gf_low, gf_high)
        } else {
            gf_low
        };

        self.raw_gf_ceiling_at(gf, surface_pressure)
    }

    /// Compute ceiling pressure for all compartments at a given GF value.
    ///
    /// For compartment i with gradient factor gf (0.0–1.0):
    ///   ceiling_i = (p_total_i - a_i * gf) / (gf / b_i - gf + 1)
    fn raw_gf_ceiling_at(&self, gf: f64, surface_pressure: f64) -> f64 {
        let mut max_ceil = surface_pressure;
        for i in 0..NUM_COMPARTMENTS {
            let p_total = self.p_n2[i] + self.p_he[i];
            let (a, b) = self.weighted_ab(i);

            let denom = gf / b - gf + 1.0;
            if denom.abs() < 1e-10 {
                continue;
            }
            let ceil = (p_total - a * gf) / denom;
            if ceil > max_ceil {
                max_ceil = ceil;
            }
        }
        max_ceil
    }
}

// ============================================================================
// GF Interpolation
// ============================================================================

/// Baker GF interpolation: linear from gf_low at first_stop_depth to gf_high at surface.
fn gf_at_depth(depth_m: f64, first_stop_depth_m: f64, gf_low: f64, gf_high: f64) -> f64 {
    if first_stop_depth_m <= 0.0 {
        return gf_high;
    }
    let ratio = (depth_m / first_stop_depth_m).clamp(0.0, 1.0);
    gf_high + (gf_low - gf_high) * ratio
}

/// Round a depth up to the next stop interval (e.g., 3m multiples).
fn round_up_to_stop(depth_m: f64, stop_interval: f64) -> f64 {
    if depth_m <= 0.0 {
        return 0.0;
    }
    (depth_m / stop_interval).ceil() * stop_interval
}

// ============================================================================
// Planner Parameters
// ============================================================================

/// A gas available for breathing during ascent planning.
#[derive(Clone)]
struct PlanGas {
    fo2: f64,
    fhe: f64,
    /// Switch to this gas at or above this depth (metres). `None` = bottom gas.
    switch_depth_m: Option<f64>,
}

/// Bundled parameters for the deco stop planner and TTS computation.
struct PlanParams {
    /// Available gases sorted by switch depth descending (deepest switch first, bottom gas last).
    gases: Vec<PlanGas>,
    /// CCR setpoint PPO2 in bar. `None` = open circuit.
    ppo2: Option<f64>,
    surface_p: f64,
    ascent_rate_m_min: f64,
    last_stop_depth: f64,
    stop_interval: f64,
    gf_low: f64,
    gf_high: f64,
    first_stop_depth_m: Option<f64>,
}

/// Maximum PPO2 for computing default switch depths (MOD).
const MAX_PPO2_SWITCH: f64 = 1.6;

impl PlanParams {
    /// Get the gas to breathe at a given depth. Uses the richest available
    /// gas whose switch depth is at or above the current depth.
    fn gas_at_depth(&self, depth_m: f64) -> &PlanGas {
        for gas in &self.gases {
            if let Some(switch_depth) = gas.switch_depth_m {
                if depth_m <= switch_depth {
                    return gas;
                }
            }
        }
        // Bottom gas (no switch depth) is always last
        self.gases.last().unwrap_or(&PlanGas {
            fo2: AIR_FO2,
            fhe: 0.0,
            switch_depth_m: None,
        })
    }

    /// Build a PlanParams from the engine's current state and gas mixes.
    #[allow(clippy::too_many_arguments)]
    fn from_engine(
        gas_mixes: &std::collections::HashMap<i32, (f64, f64)>,
        current_gas_index: i32,
        ppo2: Option<f64>,
        surface_p: f64,
        ascent_rate: f64,
        last_stop_depth: f64,
        stop_interval: f64,
        gf_low: f64,
        gf_high: f64,
        first_stop_depth_m: Option<f64>,
    ) -> Self {
        let mut gases: Vec<PlanGas> = Vec::new();
        let mut bottom_gas: Option<PlanGas> = None;

        for (&mix_idx, &(fo2, fhe)) in gas_mixes {
            if mix_idx == current_gas_index || mix_idx == 0 {
                // Bottom gas or current gas — no switch depth
                bottom_gas = Some(PlanGas {
                    fo2,
                    fhe,
                    switch_depth_m: None,
                });
            } else if fo2 > 0.0 {
                // Deco gas — compute MOD at 1.6 PPO2 as default switch depth
                let mod_m = (MAX_PPO2_SWITCH / fo2 - 1.0) * 10.0;
                gases.push(PlanGas {
                    fo2,
                    fhe,
                    switch_depth_m: Some(mod_m.max(0.0)),
                });
            }
        }

        // Sort deco gases by switch depth descending (deepest first)
        gases.sort_by(|a, b| {
            b.switch_depth_m
                .unwrap_or(0.0)
                .partial_cmp(&a.switch_depth_m.unwrap_or(0.0))
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        // Bottom gas goes last
        if let Some(bg) = bottom_gas {
            gases.push(bg);
        } else {
            gases.push(PlanGas {
                fo2: AIR_FO2,
                fhe: 0.0,
                switch_depth_m: None,
            });
        }

        PlanParams {
            gases,
            ppo2,
            surface_p,
            ascent_rate_m_min: ascent_rate,
            last_stop_depth,
            stop_interval,
            gf_low,
            gf_high,
            first_stop_depth_m,
        }
    }
}

// ============================================================================
// TTS Computation
// ============================================================================

/// Compute Time-To-Surface from current depth and tissue state.
///
/// Clones tissues, simulates ascent with stops, returns total time in seconds.
fn compute_tts(tissues: &EngineTissueState, current_depth_m: f64, pp: &PlanParams) -> i32 {
    let (stops, _truncated) = plan_deco_stops(tissues, current_depth_m, pp);

    let mut total_sec = 0.0;
    let mut depth = current_depth_m;

    for stop in &stops {
        // Travel time to stop
        let travel_m = depth - stop.depth_m as f64;
        if travel_m > 0.0 {
            total_sec += (travel_m / pp.ascent_rate_m_min) * 60.0;
        }
        total_sec += stop.duration_sec as f64;
        depth = stop.depth_m as f64;
    }

    // Final ascent from last stop (or current depth if no stops) to surface
    if depth > 0.0 {
        total_sec += (depth / pp.ascent_rate_m_min) * 60.0;
    }

    total_sec.ceil() as i32
}

// ============================================================================
// NDL Computation
// ============================================================================

/// Compute No-Decompression Limit via binary search.
///
/// Finds the time (seconds) the diver can stay at current depth before
/// a GF-adjusted ceiling appears. Returns 0 if already in deco.
/// Precision: +/- 5 seconds.
#[allow(clippy::too_many_arguments)]
fn compute_ndl(
    tissues: &EngineTissueState,
    current_depth_m: f64,
    fo2: f64,
    fhe: f64,
    ppo2: Option<f64>,
    surface_p: f64,
    gf_low: f64,
    _gf_high: f64,
) -> i32 {
    if current_depth_m <= 0.0 {
        return 0;
    }

    let ambient_p = depth_to_pressure(current_depth_m, surface_p);
    let (fn2, fhe_frac) = inspired_fractions(fo2, fhe, ppo2, ambient_p);
    let p_inspired_n2 = (ambient_p - P_WATER_VAPOR) * fn2;
    let p_inspired_he = (ambient_p - P_WATER_VAPOR) * fhe_frac;

    // Binary search: find max time before ceiling appears
    // Phase 1: double time until ceiling appears (max 200 min)
    let mut lo: f64 = 0.0;
    let mut hi: f64 = 60.0; // start with 1 min
    let max_time = 12000.0; // 200 min

    while hi < max_time {
        let mut trial = tissues.clone();
        trial.update(hi, p_inspired_n2, p_inspired_he);
        let ceil_p = trial.raw_gf_ceiling_at(gf_low, surface_p);
        let ceil_depth = pressure_to_depth(ceil_p, surface_p);
        if ceil_depth > 0.0 {
            break;
        }
        lo = hi;
        hi *= 2.0;
    }

    if hi >= max_time {
        // Check if ceiling ever appears at max_time
        let mut trial = tissues.clone();
        trial.update(max_time, p_inspired_n2, p_inspired_he);
        let ceil_p = trial.raw_gf_ceiling_at(gf_low, surface_p);
        let ceil_depth = pressure_to_depth(ceil_p, surface_p);
        if ceil_depth <= 0.0 {
            return max_time as i32;
        }
        hi = max_time;
    }

    // Phase 2: bisect to ±5 sec precision
    while (hi - lo) > 5.0 {
        let mid = (lo + hi) / 2.0;
        let mut trial = tissues.clone();
        trial.update(mid, p_inspired_n2, p_inspired_he);
        let ceil_p = trial.raw_gf_ceiling_at(gf_low, surface_p);
        let ceil_depth = pressure_to_depth(ceil_p, surface_p);
        if ceil_depth > 0.0 {
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

/// Plan deco stops from current depth/tissue state to the surface.
///
/// NOTE: The planner uses OC gas fractions for ascent computation, even for
/// CCR profiles. This is the conservative (bailout) assumption — CCR divers
/// plan for loss-of-loop scenarios. True CCR ascent planning with setpoint
/// schedules is a future enhancement.
///
/// Algorithm:
/// 1. Find the first stop (ceiling rounded up to stop_interval)
/// 2. Ascend at ascent_rate, updating tissues during travel
/// 3. At each stop: simulate 1-minute increments until ceiling clears to next stop
/// 4. Repeat until surface
fn plan_deco_stops(
    tissues: &EngineTissueState,
    current_depth_m: f64,
    pp: &PlanParams,
) -> (Vec<DecoStop>, bool) {
    let mut tissues = tissues.clone();
    let mut stops = Vec::new();
    let mut depth = current_depth_m;
    let mut truncated = false;

    // Determine first stop from ceiling
    let ceil_p = tissues.gf_ceiling(pp.gf_low, pp.gf_high, pp.first_stop_depth_m, pp.surface_p);
    let ceil_depth = pressure_to_depth(ceil_p, pp.surface_p);
    let mut stop_depth = round_up_to_stop(ceil_depth, pp.stop_interval);

    // Ensure stop_depth >= last_stop_depth if there's any obligation
    if stop_depth > 0.0 && stop_depth < pp.last_stop_depth {
        stop_depth = pp.last_stop_depth;
    }

    // Use actual first stop for GF interpolation if not already set
    let first_stop = pp.first_stop_depth_m.unwrap_or(stop_depth);

    if stop_depth <= 0.0 {
        return (stops, false); // No deco obligation
    }

    // Ascend to first stop, updating tissues during travel
    {
        let gas = pp.gas_at_depth(stop_depth);
        ascend_to(
            &mut tissues,
            &mut depth,
            stop_depth,
            gas.fo2,
            gas.fhe,
            pp.ppo2,
            pp.surface_p,
            pp.ascent_rate_m_min,
        );
    }

    // Process stops from deep to shallow
    let mut current_stop = stop_depth;
    let max_total_stop_time = 36000.0; // 10 hour safety limit

    while current_stop >= pp.last_stop_depth {
        let next_stop = if current_stop > pp.last_stop_depth {
            (current_stop - pp.stop_interval).max(pp.last_stop_depth)
        } else {
            0.0 // After last stop, need to clear to surface
        };

        let mut stop_time_sec: f64 = 0.0;

        // Simulate 1-minute increments until ceiling clears to next stop
        loop {
            let gf = gf_at_depth(current_stop, first_stop, pp.gf_low, pp.gf_high);
            let ceil_p = tissues.raw_gf_ceiling_at(gf, pp.surface_p);
            let ceil_depth = pressure_to_depth(ceil_p, pp.surface_p);

            if ceil_depth <= next_stop {
                break;
            }

            // Wait 60 seconds at this stop (using the gas available at this depth)
            let gas = pp.gas_at_depth(current_stop);
            let ambient_p = depth_to_pressure(current_stop, pp.surface_p);
            let ppo2_at_stop = pp.ppo2.map(|sp| sp.min(ambient_p));
            let (fn2, fhe_frac) = inspired_fractions(gas.fo2, gas.fhe, ppo2_at_stop, ambient_p);
            let p_inspired_n2 = (ambient_p - P_WATER_VAPOR) * fn2;
            let p_inspired_he = (ambient_p - P_WATER_VAPOR) * fhe_frac;
            tissues.update(60.0, p_inspired_n2, p_inspired_he);
            stop_time_sec += 60.0;

            if stop_time_sec > max_total_stop_time {
                truncated = true;
                break; // Safety limit
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

        // Ascend to next stop (using gas available at the shallower depth)
        let next_gas = pp.gas_at_depth(next_stop);
        ascend_to(
            &mut tissues,
            &mut depth,
            next_stop,
            next_gas.fo2,
            next_gas.fhe,
            pp.ppo2,
            pp.surface_p,
            pp.ascent_rate_m_min,
        );
        current_stop = next_stop;
    }

    (stops, truncated)
}

/// Simulate ascent between two depths, updating tissue state during travel.
#[allow(clippy::too_many_arguments)]
fn ascend_to(
    tissues: &mut EngineTissueState,
    current_depth: &mut f64,
    target_depth: f64,
    fo2: f64,
    fhe: f64,
    ppo2: Option<f64>,
    surface_p: f64,
    ascent_rate_m_min: f64,
) {
    let travel_m = *current_depth - target_depth;
    if travel_m <= 0.0 {
        *current_depth = target_depth;
        return;
    }

    let travel_sec = (travel_m / ascent_rate_m_min) * 60.0;
    let avg_depth = (*current_depth + target_depth) / 2.0;
    let ambient_p = depth_to_pressure(avg_depth, surface_p);
    let ppo2_clamped = ppo2.map(|sp| sp.min(ambient_p));
    let (fn2, fhe_frac) = inspired_fractions(fo2, fhe, ppo2_clamped, ambient_p);
    let p_inspired_n2 = (ambient_p - P_WATER_VAPOR) * fn2;
    let p_inspired_he = (ambient_p - P_WATER_VAPOR) * fhe_frac;
    tissues.update(travel_sec, p_inspired_n2, p_inspired_he);

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

    fn sample_with_gas(t_sec: i32, depth_m: f32, gasmix_index: i32) -> SampleInput {
        SampleInput {
            t_sec,
            depth_m,
            temp_c: 20.0,
            setpoint_ppo2: None,
            ceiling_m: None,
            gf99: None,
            gasmix_index: Some(gasmix_index),
            ppo2: None,
            tts_sec: None,
            ndl_sec: None,
            deco_stop_depth_m: None,
            at_plus_five_tts_min: None,
        }
    }

    // ── GF ceiling math ───────────────────────────────────────────────────

    #[test]
    fn test_gf_ceiling_known_tissue_state() {
        // Manually set tissue state and verify ceiling computation
        let surface_p = DEFAULT_SURFACE_PRESSURE;
        let mut tissues = EngineTissueState::surface_equilibrium(surface_p);

        // Simulate 20 min at 30m on air to load tissues
        let ambient_p = depth_to_pressure(30.0, surface_p);
        let fn2 = AIR_FN2;
        let p_inspired_n2 = (ambient_p - P_WATER_VAPOR) * fn2;
        tissues.update(20.0 * 60.0, p_inspired_n2, 0.0);

        // With GF 100/100 (no conservatism), ceiling should exist after 20 min at 30m
        let ceil_p = tissues.raw_gf_ceiling_at(1.0, surface_p);
        let ceil_depth = pressure_to_depth(ceil_p, surface_p);
        assert!(
            ceil_depth > 0.0,
            "Should have ceiling after 20 min at 30m, got depth={ceil_depth}"
        );

        // With GF 50/85, ceiling should be deeper (more conservative)
        let ceil_p_conservative = tissues.raw_gf_ceiling_at(0.5, surface_p);
        let ceil_depth_conservative = pressure_to_depth(ceil_p_conservative, surface_p);
        assert!(
            ceil_depth_conservative > ceil_depth,
            "Lower GF should produce deeper ceiling: {ceil_depth_conservative} vs {ceil_depth}"
        );
    }

    #[test]
    fn test_gf_ceiling_formula() {
        // Verify the GF ceiling formula against hand calculation for compartment 0
        let surface_p = DEFAULT_SURFACE_PRESSURE;
        let mut tissues = EngineTissueState {
            p_n2: [0.0; NUM_COMPARTMENTS],
            p_he: [0.0; NUM_COMPARTMENTS],
        };
        // Set compartment 0 to a known pressure
        tissues.p_n2[0] = 3.5; // bar — heavily loaded fast tissue
                               // All others at surface equilibrium
        let p_n2_surf = (surface_p - P_WATER_VAPOR) * AIR_FN2;
        for i in 1..NUM_COMPARTMENTS {
            tissues.p_n2[i] = p_n2_surf;
        }

        // Hand calculation for compartment 0, GF = 1.0:
        // ceiling = (p_total - a * gf) / (gf / b - gf + 1)
        // = (3.5 - 1.1696 * 1.0) / (1.0 / 0.5578 - 1.0 + 1.0)
        // = (3.5 - 1.1696) / (1.79275...)
        // = 2.3304 / 1.79275 = 1.2998...
        let gf = 1.0;
        let expected_ceil = (3.5 - A_N2[0] * gf) / (gf / B_N2[0] - gf + 1.0);
        let actual_ceil = tissues.raw_gf_ceiling_at(gf, surface_p);
        // raw_gf_ceiling_at returns max(ceil, surface_p), so it should be the hand-calculated value
        assert!(
            (actual_ceil - expected_ceil).abs() < 0.001,
            "Ceiling: expected {expected_ceil:.4}, got {actual_ceil:.4}"
        );
    }

    // ── GF interpolation ──────────────────────────────────────────────────

    #[test]
    fn test_gf_interpolation() {
        // At first stop depth, GF should be gf_low
        assert!((gf_at_depth(18.0, 18.0, 0.5, 0.85) - 0.5).abs() < 1e-10);
        // At surface, GF should be gf_high
        assert!((gf_at_depth(0.0, 18.0, 0.5, 0.85) - 0.85).abs() < 1e-10);
        // At halfway, GF should be midpoint
        let mid = gf_at_depth(9.0, 18.0, 0.5, 0.85);
        assert!(
            (mid - 0.675).abs() < 1e-10,
            "Midpoint GF: expected 0.675, got {mid}"
        );
    }

    #[test]
    fn test_round_up_to_stop() {
        assert_eq!(round_up_to_stop(0.0, 3.0), 0.0);
        assert_eq!(round_up_to_stop(2.5, 3.0), 3.0);
        assert_eq!(round_up_to_stop(3.0, 3.0), 3.0);
        assert_eq!(round_up_to_stop(3.1, 3.0), 6.0);
        assert_eq!(round_up_to_stop(15.5, 3.0), 18.0);
    }

    // ── NDL at recreational depths ────────────────────────────────────────

    #[test]
    fn test_ndl_18m_air() {
        // 18m on air with GF 100/100 should give NDL around 51–57 min
        // (PADI: 56 min, DSAT tables)
        let tissues = EngineTissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE);
        let ndl = compute_ndl(
            &tissues,
            18.0,
            AIR_FO2,
            0.0,
            None,
            DEFAULT_SURFACE_PRESSURE,
            1.0,
            1.0,
        );
        let ndl_min = ndl as f64 / 60.0;
        assert!(
            (46.0..=62.0).contains(&ndl_min),
            "NDL at 18m should be ~51-57 min, got {ndl_min:.1} min"
        );
    }

    #[test]
    fn test_ndl_30m_air() {
        // 30m on air with GF 100/100 should give NDL around 16–22 min
        // (PADI: 20 min, Bühlmann raw is ~16-20 min)
        let tissues = EngineTissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE);
        let ndl = compute_ndl(
            &tissues,
            30.0,
            AIR_FO2,
            0.0,
            None,
            DEFAULT_SURFACE_PRESSURE,
            1.0,
            1.0,
        );
        let ndl_min = ndl as f64 / 60.0;
        assert!(
            (14.0..=25.0).contains(&ndl_min),
            "NDL at 30m should be ~16-22 min, got {ndl_min:.1} min"
        );
    }

    #[test]
    fn test_ndl_surface() {
        // At surface, NDL should be 0 (no depth)
        let tissues = EngineTissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE);
        let ndl = compute_ndl(
            &tissues,
            0.0,
            AIR_FO2,
            0.0,
            None,
            DEFAULT_SURFACE_PRESSURE,
            1.0,
            1.0,
        );
        assert_eq!(ndl, 0);
    }

    // ── Deco schedule tests ───────────────────────────────────────────────

    #[test]
    fn test_deco_schedule_30m_20min_air_gf50_85() {
        // 30m for 20 min on air with GF 50/85 should produce deco stops
        let engine = BuhlmannEngine;
        let mut samples = vec![sample(0, 0.0)];
        // Descent to 30m over 2 min
        samples.push(sample(120, 30.0));
        // Bottom time: stay at 30m for 20 min total bottom time
        samples.push(sample(1200, 30.0));

        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples,
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: Some(9.0),
            last_stop_depth_m: Some(3.0),
            stop_interval_m: Some(3.0),
            gf_low: Some(50),
            gf_high: Some(85),
            thalmann_pdcs: None,
            plan_ascent: true,
        };

        let result = engine.simulate(&params).unwrap();

        // Should have deco stops
        assert!(
            !result.deco_stops.is_empty(),
            "30m/20min GF 50/85 should produce deco stops"
        );

        // Total deco time should be reasonable (2-10 min for this profile)
        let total_deco_min = result.total_deco_time_sec as f64 / 60.0;
        assert!(
            (1.0..=15.0).contains(&total_deco_min),
            "Total deco time should be 1-15 min, got {total_deco_min:.1} min"
        );

        // Stops should be at multiples of 3m
        for stop in &result.deco_stops {
            assert!(
                (stop.depth_m % 3.0).abs() < 0.01,
                "Stop depth {} should be multiple of 3m",
                stop.depth_m
            );
        }

        // Last stop should be at 3m
        if let Some(last) = result.deco_stops.last() {
            assert!(
                (last.depth_m - 3.0).abs() < 0.01,
                "Last stop should be at 3m, got {}",
                last.depth_m
            );
        }
    }

    #[test]
    fn test_deco_schedule_45m_20min_trimix_gf30_85() {
        // 45m for 20 min on trimix 21/35 with GF 30/85 — deep deco profile
        let engine = BuhlmannEngine;
        let mut samples = vec![sample_with_gas(0, 0.0, 0)];
        samples.push(sample_with_gas(180, 45.0, 0)); // 3 min descent
        samples.push(sample_with_gas(1200, 45.0, 0)); // 20 min bottom

        let gas_mixes = vec![crate::buhlmann::GasMixInput {
            mix_index: 0,
            o2_fraction: 0.21,
            he_fraction: 0.35,
        }];

        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples,
            gas_mixes,
            surface_pressure_bar: None,
            ascent_rate_m_min: Some(9.0),
            last_stop_depth_m: Some(3.0),
            stop_interval_m: Some(3.0),
            gf_low: Some(30),
            gf_high: Some(85),
            thalmann_pdcs: None,
            plan_ascent: true,
        };

        let result = engine.simulate(&params).unwrap();

        // Deep profile with low GF should have multiple stops
        assert!(
            result.deco_stops.len() >= 2,
            "45m/20min trimix GF 30/85 should have multiple stops, got {}",
            result.deco_stops.len()
        );

        // Should have deep stops (above 3m)
        let has_deep_stop = result.deco_stops.iter().any(|s| s.depth_m > 3.0);
        assert!(has_deep_stop, "Should have deep stops with GF 30/85 at 45m");

        // Total deco time should be substantial
        let total_deco_min = result.total_deco_time_sec as f64 / 60.0;
        assert!(
            total_deco_min > 5.0,
            "Total deco should be > 5 min, got {total_deco_min:.1}"
        );
    }

    // ── GF 100/100: raw M-values ──────────────────────────────────────────

    #[test]
    fn test_gf_100_100_no_conservatism() {
        // GF 100/100 should produce shorter deco than GF 50/85
        let engine = BuhlmannEngine;
        let samples = vec![sample(0, 0.0), sample(120, 30.0), sample(1500, 30.0)];

        let params_100 = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples: samples.clone(),
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: Some(9.0),
            last_stop_depth_m: Some(3.0),
            stop_interval_m: Some(3.0),
            gf_low: Some(100),
            gf_high: Some(100),
            thalmann_pdcs: None,
            plan_ascent: true,
        };

        let params_50_85 = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples,
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: Some(9.0),
            last_stop_depth_m: Some(3.0),
            stop_interval_m: Some(3.0),
            gf_low: Some(50),
            gf_high: Some(85),
            thalmann_pdcs: None,
            plan_ascent: true,
        };

        let result_100 = engine.simulate(&params_100).unwrap();
        let result_50_85 = engine.simulate(&params_50_85).unwrap();

        assert!(
            result_100.total_deco_time_sec <= result_50_85.total_deco_time_sec,
            "GF 100/100 deco ({}) should be <= GF 50/85 deco ({})",
            result_100.total_deco_time_sec,
            result_50_85.total_deco_time_sec
        );
    }

    // ── SurfGF/GF99 regression ────────────────────────────────────────────

    #[test]
    fn test_surfgf_gf99_matches_existing() {
        // Run both the new engine and existing compute_surface_gf on same profile
        // and verify SurfGF/GF99 match
        let samples = vec![
            sample(0, 0.0),
            sample(60, 30.0),
            sample(600, 30.0),
            sample(900, 15.0),
            sample(1200, 0.0),
        ];

        // Existing API
        let existing = crate::buhlmann::compute_surface_gf(&samples, &[], None);

        // New engine with GF 100/100 (should not affect SurfGF/GF99 which are raw)
        let engine = BuhlmannEngine;
        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples: samples.clone(),
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: None,
            last_stop_depth_m: None,
            stop_interval_m: None,
            gf_low: Some(100),
            gf_high: Some(100),
            thalmann_pdcs: None,
            plan_ascent: false,
        };
        let result = engine.simulate(&params).unwrap();

        assert_eq!(existing.len(), result.points.len());
        for (i, (old, new)) in existing.iter().zip(result.points.iter()).enumerate() {
            assert!(
                (old.surface_gf - new.surface_gf).abs() < 0.1,
                "Sample {i}: SurfGF mismatch: existing={}, new={}",
                old.surface_gf,
                new.surface_gf
            );
            assert!(
                (old.gf99 - new.gf99).abs() < 0.1,
                "Sample {i}: GF99 mismatch: existing={}, new={}",
                old.gf99,
                new.gf99
            );
        }
    }

    // ── Per-sample point fields ───────────────────────────────────────────

    #[test]
    fn test_per_sample_point_fields() {
        let engine = BuhlmannEngine;
        let samples = vec![
            sample(0, 0.0),
            sample(120, 30.0),
            sample(1200, 30.0),
            sample(1500, 10.0),
            sample(1800, 0.0),
        ];

        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples,
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: None,
            last_stop_depth_m: None,
            stop_interval_m: None,
            gf_low: Some(50),
            gf_high: Some(85),
            thalmann_pdcs: None,
            plan_ascent: false,
        };

        let result = engine.simulate(&params).unwrap();

        // Surface point should have low GF99 and SurfGF
        assert!(result.points[0].surface_gf < 1.0);
        assert!(result.points[0].ceiling_m == 0.0 || result.points[0].ceiling_m < 0.01);

        // At depth, GF99 should be <= SurfGF
        for pt in &result.points {
            if pt.depth_m > 1.0 {
                assert!(
                    pt.gf99 <= pt.surface_gf + 0.1,
                    "GF99 ({}) should be <= SurfGF ({}) at depth {}",
                    pt.gf99,
                    pt.surface_gf,
                    pt.depth_m
                );
            }
        }

        // Model in result
        assert_eq!(result.model, DecoModel::BuhlmannZhl16c);
    }

    // ── Error cases ───────────────────────────────────────────────────────

    #[test]
    fn test_empty_samples_error() {
        let engine = BuhlmannEngine;
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
            thalmann_pdcs: None,
            plan_ascent: false,
        };

        let result = engine.simulate(&params);
        assert!(matches!(result, Err(DecoSimError::EmptySamples { .. })));
    }

    #[test]
    fn test_invalid_gf_low_gt_high() {
        let engine = BuhlmannEngine;
        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples: vec![sample(0, 0.0)],
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: None,
            last_stop_depth_m: None,
            stop_interval_m: None,
            gf_low: Some(90),
            gf_high: Some(70),
            thalmann_pdcs: None,
            plan_ascent: false,
        };

        let result = engine.simulate(&params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_invalid_gf_zero() {
        let engine = BuhlmannEngine;
        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples: vec![sample(0, 0.0)],
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: None,
            last_stop_depth_m: None,
            stop_interval_m: None,
            gf_low: Some(0),
            gf_high: Some(85),
            thalmann_pdcs: None,
            plan_ascent: false,
        };

        let result = engine.simulate(&params);
        assert!(matches!(result, Err(DecoSimError::InvalidParam { .. })));
    }

    #[test]
    fn test_invalid_negative_params() {
        let engine = BuhlmannEngine;
        // Negative ascent rate
        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples: vec![sample(0, 0.0)],
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: Some(-1.0),
            last_stop_depth_m: None,
            stop_interval_m: None,
            gf_low: None,
            gf_high: None,
            thalmann_pdcs: None,
            plan_ascent: false,
        };
        assert!(matches!(
            engine.simulate(&params),
            Err(DecoSimError::InvalidParam { .. })
        ));

        // Zero stop interval
        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples: vec![sample(0, 0.0)],
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: None,
            last_stop_depth_m: None,
            stop_interval_m: Some(0.0),
            gf_low: None,
            gf_high: None,
            thalmann_pdcs: None,
            plan_ascent: false,
        };
        assert!(matches!(
            engine.simulate(&params),
            Err(DecoSimError::InvalidParam { .. })
        ));
    }

    // ── CCR PPO2 test ─────────────────────────────────────────────────────

    #[test]
    fn test_ccr_ppo2_handling() {
        let engine = BuhlmannEngine;
        let mut samples = vec![SampleInput {
            t_sec: 0,
            depth_m: 0.0,
            temp_c: 20.0,
            setpoint_ppo2: None,
            ceiling_m: None,
            gf99: None,
            gasmix_index: Some(0),
            ppo2: Some(0.7),
            tts_sec: None,
            ndl_sec: None,
            deco_stop_depth_m: None,
            at_plus_five_tts_min: None,
        }];
        // At 30m with PPO2 of 1.3 on 21/35 diluent
        samples.push(SampleInput {
            t_sec: 120,
            depth_m: 30.0,
            temp_c: 18.0,
            setpoint_ppo2: None,
            ceiling_m: None,
            gf99: None,
            gasmix_index: None,
            ppo2: Some(1.3),
            tts_sec: None,
            ndl_sec: None,
            deco_stop_depth_m: None,
            at_plus_five_tts_min: None,
        });
        samples.push(SampleInput {
            t_sec: 1200,
            depth_m: 30.0,
            temp_c: 18.0,
            setpoint_ppo2: None,
            ceiling_m: None,
            gf99: None,
            gasmix_index: None,
            ppo2: Some(1.3),
            tts_sec: None,
            ndl_sec: None,
            deco_stop_depth_m: None,
            at_plus_five_tts_min: None,
        });

        let gas_mixes = vec![crate::buhlmann::GasMixInput {
            mix_index: 0,
            o2_fraction: 0.21,
            he_fraction: 0.35,
        }];

        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples,
            gas_mixes,
            surface_pressure_bar: None,
            ascent_rate_m_min: None,
            last_stop_depth_m: None,
            stop_interval_m: None,
            gf_low: Some(100),
            gf_high: Some(100),
            thalmann_pdcs: None,
            plan_ascent: false,
        };

        let result = engine.simulate(&params).unwrap();
        // With CCR at PPO2=1.3 on trimix diluent, N2 loading should be lower
        // than OC air, so SurfGF should be lower
        let last_pt = result.points.last().unwrap();
        assert!(
            last_pt.surface_gf > 0.0,
            "SurfGF should be positive at depth"
        );

        // Compare with OC air at same profile
        let oc_params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples: vec![sample(0, 0.0), sample(120, 30.0), sample(1200, 30.0)],
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: None,
            last_stop_depth_m: None,
            stop_interval_m: None,
            gf_low: Some(100),
            gf_high: Some(100),
            thalmann_pdcs: None,
            plan_ascent: false,
        };
        let oc_result = engine.simulate(&oc_params).unwrap();
        let oc_last = oc_result.points.last().unwrap();

        // CCR with higher O2 fraction means less inert gas loading
        assert!(
            last_pt.surface_gf < oc_last.surface_gf,
            "CCR SurfGF ({}) should be < OC SurfGF ({})",
            last_pt.surface_gf,
            oc_last.surface_gf
        );
    }

    // ── TTS validation ────────────────────────────────────────────────────

    #[test]
    fn test_tts_positive_when_in_deco() {
        // After 25 min at 30m on air with GF 50/85, should have TTS > 0
        let engine = BuhlmannEngine;
        let samples = vec![sample(0, 0.0), sample(120, 30.0), sample(1500, 30.0)];

        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples,
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: Some(9.0),
            last_stop_depth_m: Some(3.0),
            stop_interval_m: Some(3.0),
            gf_low: Some(50),
            gf_high: Some(85),
            thalmann_pdcs: None,
            plan_ascent: false,
        };

        let result = engine.simulate(&params).unwrap();
        let last_pt = result.points.last().unwrap();

        // If ceiling > 0, TTS must be positive (ascent travel + stop time)
        if last_pt.ceiling_m > 0.0 {
            assert!(
                last_pt.tts_sec > 0,
                "TTS should be > 0 when ceiling={}, got tts={}",
                last_pt.ceiling_m,
                last_pt.tts_sec
            );
            // TTS should include at least the ascent travel time from 30m at 9m/min
            let min_travel_sec = (30.0 / 9.0 * 60.0) as i32;
            assert!(
                last_pt.tts_sec >= min_travel_sec,
                "TTS ({}) should be >= min travel time ({})",
                last_pt.tts_sec,
                min_travel_sec
            );
        }
    }

    #[test]
    fn test_tts_increases_with_bottom_time() {
        // Longer bottom time at depth should produce higher TTS
        let engine = BuhlmannEngine;

        let make_params = |bottom_sec: i32| DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples: vec![sample(0, 0.0), sample(120, 30.0), sample(bottom_sec, 30.0)],
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: Some(9.0),
            last_stop_depth_m: Some(3.0),
            stop_interval_m: Some(3.0),
            gf_low: Some(50),
            gf_high: Some(85),
            thalmann_pdcs: None,
            plan_ascent: false,
        };

        let result_short = engine.simulate(&make_params(1200)).unwrap();
        let result_long = engine.simulate(&make_params(1800)).unwrap();

        let tts_short = result_short.points.last().unwrap().tts_sec;
        let tts_long = result_long.points.last().unwrap().tts_sec;

        // Longer bottom time should have more or equal deco obligation
        assert!(
            tts_long >= tts_short,
            "TTS should increase with bottom time: short={tts_short}, long={tts_long}"
        );
    }

    #[test]
    fn test_ndl_decreases_with_depth() {
        // Deeper depth should have shorter NDL
        let engine = BuhlmannEngine;

        let make_params = |depth: f32| DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples: vec![sample(0, 0.0), sample(120, depth)],
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: None,
            last_stop_depth_m: None,
            stop_interval_m: None,
            gf_low: Some(100),
            gf_high: Some(100),
            thalmann_pdcs: None,
            plan_ascent: false,
        };

        let result_18 = engine.simulate(&make_params(18.0)).unwrap();
        let result_30 = engine.simulate(&make_params(30.0)).unwrap();

        let ndl_18 = result_18.points.last().unwrap().ndl_sec;
        let ndl_30 = result_30.points.last().unwrap().ndl_sec;

        assert!(
            ndl_18 > ndl_30,
            "NDL at 18m ({ndl_18}) should be > NDL at 30m ({ndl_30})"
        );
    }

    #[test]
    fn test_deco_stop_durations_positive() {
        // All deco stops should have positive duration
        let engine = BuhlmannEngine;
        let samples = vec![sample(0, 0.0), sample(120, 30.0), sample(1500, 30.0)];

        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples,
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: Some(9.0),
            last_stop_depth_m: Some(3.0),
            stop_interval_m: Some(3.0),
            gf_low: Some(50),
            gf_high: Some(85),
            thalmann_pdcs: None,
            plan_ascent: true,
        };

        let result = engine.simulate(&params).unwrap();
        for stop in &result.deco_stops {
            assert!(
                stop.duration_sec > 0,
                "Stop at {}m has non-positive duration: {}",
                stop.depth_m,
                stop.duration_sec
            );
            assert!(
                stop.depth_m >= 3.0,
                "Stop depth {} below last stop depth",
                stop.depth_m
            );
        }
    }

    // ── DecoSimError Display ──────────────────────────────────────────────

    #[test]
    fn test_deco_sim_error_display() {
        let e = DecoSimError::EmptySamples {
            msg: "no data".to_string(),
        };
        assert!(format!("{e}").contains("no data"));

        let e = DecoSimError::UnsupportedModel {
            msg: "thalmann".to_string(),
        };
        assert!(format!("{e}").contains("thalmann"));

        let e = DecoSimError::InvalidParam {
            msg: "bad gf".to_string(),
        };
        assert!(format!("{e}").contains("bad gf"));
    }

    // ── Coverage gap tests ────────────────────────────────────────────────

    #[test]
    fn test_tissue_update_zero_dt() {
        // Covers line 240: dt_sec <= 0 guard in EngineTissueState::update
        let mut tissues = EngineTissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE);
        let p_before = tissues.p_n2[0];
        tissues.update(0.0, 3.0, 0.0);
        assert_eq!(
            tissues.p_n2[0], p_before,
            "Zero dt should not change tissues"
        );
        tissues.update(-1.0, 3.0, 0.0);
        assert_eq!(
            tissues.p_n2[0], p_before,
            "Negative dt should not change tissues"
        );
    }

    #[test]
    fn test_weighted_ab_zero_tissue_pressure() {
        // Covers line 256: p_total <= 1e-10 fallback in weighted_ab
        let tissues = EngineTissueState {
            p_n2: [0.0; NUM_COMPARTMENTS],
            p_he: [0.0; NUM_COMPARTMENTS],
        };
        // compartment_gf calls weighted_ab; with zero tissue pressure it should not panic
        let gf = tissues.compartment_gf(0, DEFAULT_SURFACE_PRESSURE);
        // With zero tissue load, GF should be 0 or negative (undersaturated)
        assert!(
            gf <= 0.0,
            "Zero tissue pressure should give GF <= 0, got {gf}"
        );
    }

    #[test]
    fn test_gf_ceiling_zero_tissue_pressure() {
        // Covers lines 269, 334: denom guards in compartment_gf and raw_gf_ceiling_at
        let tissues = EngineTissueState {
            p_n2: [0.0; NUM_COMPARTMENTS],
            p_he: [0.0; NUM_COMPARTMENTS],
        };
        let ceil = tissues.raw_gf_ceiling_at(1.0, DEFAULT_SURFACE_PRESSURE);
        // Zero tissue load means no ceiling
        assert!(
            (ceil - DEFAULT_SURFACE_PRESSURE).abs() < 0.01,
            "Zero tissue pressure ceiling should be at surface, got {ceil}"
        );
    }

    #[test]
    fn test_gf_at_depth_zero_first_stop() {
        // Covers line 352: first_stop_depth_m <= 0 returns gf_high
        let gf = gf_at_depth(10.0, 0.0, 0.5, 0.85);
        assert!(
            (gf - 0.85).abs() < 1e-10,
            "Zero first stop should return gf_high, got {gf}"
        );
        let gf = gf_at_depth(10.0, -1.0, 0.5, 0.85);
        assert!(
            (gf - 0.85).abs() < 1e-10,
            "Negative first stop should return gf_high, got {gf}"
        );
    }

    #[test]
    fn test_ndl_very_shallow_returns_max() {
        // Covers lines 461-466: NDL at very shallow depth — no ceiling even at 200 min
        let tissues = EngineTissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE);
        // 3m on air — no ceiling even after 200 min, returns max_time
        let ndl = compute_ndl(
            &tissues,
            3.0,
            AIR_FO2,
            0.0,
            None,
            DEFAULT_SURFACE_PRESSURE,
            1.0,
            1.0,
        );
        assert_eq!(
            ndl, 12000,
            "NDL at 3m should hit 200 min cap, got {} sec",
            ndl
        );
    }

    #[test]
    fn test_ndl_near_max_time_with_ceiling() {
        // Covers lines 467-468: hi >= max_time AND ceiling exists at max_time.
        // Need a depth where ceiling appears between 7680 sec and 12000 sec.
        // At 15m GF 0.5 on air, NDL is shorter than at shallower depths but
        // the doubling may still overshoot. Try multiple conservative depths.
        let tissues = EngineTissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE);
        // At 12m with GF 0.4, ceiling should appear sooner
        let ndl = compute_ndl(
            &tissues,
            12.0,
            AIR_FO2,
            0.0,
            None,
            DEFAULT_SURFACE_PRESSURE,
            0.4,
            0.85,
        );
        assert!(
            ndl > 0,
            "NDL at 12m GF40 should be positive, got {} sec ({:.1} min)",
            ndl,
            ndl as f64 / 60.0
        );
    }

    #[test]
    fn test_stop_depth_below_last_stop() {
        // Covers line 521: ceiling rounds to depth below last_stop_depth
        // Use GF 100/100 with a profile that barely enters deco
        // The ceiling might round to e.g. 1.5m which gets bumped to 3m
        let engine = BuhlmannEngine;
        let samples = vec![sample(0, 0.0), sample(120, 30.0), sample(1200, 30.0)];

        // Use large stop_interval (6m) and last_stop at 6m
        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples,
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: Some(9.0),
            last_stop_depth_m: Some(6.0),
            stop_interval_m: Some(6.0),
            gf_low: Some(50),
            gf_high: Some(85),
            thalmann_pdcs: None,
            plan_ascent: true,
        };

        let result = engine.simulate(&params).unwrap();
        // All stops should be >= last_stop_depth (6m)
        for stop in &result.deco_stops {
            assert!(
                stop.depth_m >= 6.0 - 0.01,
                "Stop at {} should be >= 6m",
                stop.depth_m
            );
        }
    }

    #[test]
    fn test_result_not_truncated_normal() {
        // Verify truncated is false for normal profiles
        let engine = BuhlmannEngine;
        let samples = vec![sample(0, 0.0), sample(120, 30.0), sample(1200, 30.0)];

        let params = DecoSimParams {
            model: DecoModel::BuhlmannZhl16c,
            samples,
            gas_mixes: vec![],
            surface_pressure_bar: None,
            ascent_rate_m_min: Some(9.0),
            last_stop_depth_m: Some(3.0),
            stop_interval_m: Some(3.0),
            gf_low: Some(50),
            gf_high: Some(85),
            thalmann_pdcs: None,
            plan_ascent: true,
        };

        let result = engine.simulate(&params).unwrap();
        assert!(!result.truncated, "Normal profile should not be truncated");
    }
}
