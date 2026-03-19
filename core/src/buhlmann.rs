//! Bühlmann ZHL-16C tissue simulation for Surface Gradient Factor computation.
//!
//! Implements a full 16-compartment tissue model using the Schreiner equation
//! to simulate inert gas loading from a depth/time/gas profile. Computes
//! SurfGF (Surface Gradient Factor) — the gradient factor if the diver
//! ascended directly to the surface — for each sample point.

use crate::metrics::SampleInput;

// ============================================================================
// Physical Constants
// ============================================================================

/// Water vapour pressure in the lungs (bar), at 37°C.
const P_WATER_VAPOR: f64 = 0.0627;

/// Pressure increase per metre of seawater (bar/m).
/// 1 atm / 10 msw = 1.01325 / 10.0
const BAR_PER_METER: f64 = 0.101325;

/// Default surface atmospheric pressure (bar) at sea level.
const DEFAULT_SURFACE_PRESSURE: f64 = 1.01325;

/// Fraction of N2 in air.
const AIR_FN2: f64 = 0.7902;

/// Fraction of O2 in air (for default gas).
const AIR_FO2: f64 = 0.2095;

// ============================================================================
// ZHL-16C Compartment Constants (Bühlmann / Baker)
// ============================================================================

/// Number of tissue compartments.
const NUM_COMPARTMENTS: usize = 16;

/// N2 half-times in minutes for compartments 1–16 (ZHL-16C).
const N2_HALF_TIMES: [f64; NUM_COMPARTMENTS] = [
    5.0, 8.0, 12.5, 18.5, 27.0, 38.3, 54.3, 77.0, 109.0, 146.0, 187.0, 239.0, 305.0, 390.0, 498.0,
    635.0,
];

/// He half-times in minutes for compartments 1–16 (ZHL-16C).
const HE_HALF_TIMES: [f64; NUM_COMPARTMENTS] = [
    1.88, 3.02, 4.72, 6.99, 10.21, 14.48, 20.53, 29.11, 41.20, 55.19, 70.69, 90.34, 115.29, 147.42,
    188.24, 240.03,
];

/// N2 'a' coefficients (bar) for ZHL-16C.
const A_N2: [f64; NUM_COMPARTMENTS] = [
    1.1696, 1.0000, 0.8618, 0.7562, 0.6200, 0.5043, 0.4410, 0.4000, 0.3750, 0.3500, 0.3295, 0.3065,
    0.2835, 0.2610, 0.2480, 0.2327,
];

/// N2 'b' coefficients (dimensionless) for ZHL-16C.
const B_N2: [f64; NUM_COMPARTMENTS] = [
    0.5578, 0.6514, 0.7222, 0.7825, 0.8126, 0.8434, 0.8693, 0.8910, 0.9092, 0.9222, 0.9319, 0.9403,
    0.9477, 0.9544, 0.9602, 0.9653,
];

/// He 'a' coefficients (bar) for ZHL-16C.
const A_HE: [f64; NUM_COMPARTMENTS] = [
    1.6189, 1.3830, 1.1919, 1.0458, 0.9220, 0.8205, 0.7305, 0.6502, 0.5950, 0.5545, 0.5333, 0.5189,
    0.5181, 0.5176, 0.5172, 0.5119,
];

/// He 'b' coefficients (dimensionless) for ZHL-16C.
const B_HE: [f64; NUM_COMPARTMENTS] = [
    0.4770, 0.5747, 0.6527, 0.7223, 0.7582, 0.7957, 0.8279, 0.8553, 0.8757, 0.8903, 0.8997, 0.9073,
    0.9122, 0.9171, 0.9217, 0.9267,
];

// ============================================================================
// FFI Types
// ============================================================================

/// Gas mix definition for the simulation.
#[derive(Debug, Clone)]
pub struct GasMixInput {
    /// Index matching SampleInput::gasmix_index
    pub mix_index: i32,
    /// Fraction of O2 (0.0–1.0)
    pub o2_fraction: f64,
    /// Fraction of He (0.0–1.0)
    pub he_fraction: f64,
}

/// A single computed SurfGF data point.
#[derive(Debug, Clone)]
pub struct SurfaceGfPoint {
    /// Time offset from dive start (seconds), matching the input sample.
    pub t_sec: i32,
    /// Surface gradient factor as a percentage (0–100+).
    pub surface_gf: f32,
    /// Index (0–15) of the leading (most loaded) compartment.
    pub leading_compartment: u8,
    /// GF99: gradient factor at current ambient pressure (0–100+).
    /// Measures how loaded tissues are relative to the M-value at current depth.
    pub gf99: f32,
}

// ============================================================================
// Tissue State
// ============================================================================

/// State of the 16 tissue compartments.
#[derive(Debug, Clone)]
struct TissueState {
    /// N2 partial pressure in each compartment (bar).
    p_n2: [f64; NUM_COMPARTMENTS],
    /// He partial pressure in each compartment (bar).
    p_he: [f64; NUM_COMPARTMENTS],
}

impl TissueState {
    /// Initialise tissues at surface equilibrium (breathing air).
    fn surface_equilibrium(surface_pressure: f64) -> Self {
        let p_n2_surface = (surface_pressure - P_WATER_VAPOR) * AIR_FN2;
        let mut state = TissueState {
            p_n2: [0.0; NUM_COMPARTMENTS],
            p_he: [0.0; NUM_COMPARTMENTS],
        };
        for i in 0..NUM_COMPARTMENTS {
            state.p_n2[i] = p_n2_surface;
        }
        state
    }

    /// Update all compartments for a time interval using the Schreiner equation.
    ///
    /// `dt_sec` — exposure time in seconds.
    /// `p_inspired_n2` — inspired N2 partial pressure (bar).
    /// `p_inspired_he` — inspired He partial pressure (bar).
    fn update(&mut self, dt_sec: f64, p_inspired_n2: f64, p_inspired_he: f64) {
        if dt_sec <= 0.0 {
            return;
        }
        for i in 0..NUM_COMPARTMENTS {
            // N2
            let k_n2 = (2.0_f64.ln()) / (N2_HALF_TIMES[i] * 60.0);
            self.p_n2[i] = p_inspired_n2 + (self.p_n2[i] - p_inspired_n2) * (-k_n2 * dt_sec).exp();

            // He
            let k_he = (2.0_f64.ln()) / (HE_HALF_TIMES[i] * 60.0);
            self.p_he[i] = p_inspired_he + (self.p_he[i] - p_inspired_he) * (-k_he * dt_sec).exp();
        }
    }

    /// Compute the Surface Gradient Factor (%) and leading compartment index
    /// in a single pass over all compartments.
    fn surface_gf_and_leading(&self, surface_pressure: f64) -> (f64, usize) {
        let mut max_gf: f64 = 0.0;
        let mut leading: usize = 0;
        for i in 0..NUM_COMPARTMENTS {
            let gf = self.compartment_gf(i, surface_pressure);
            if gf > max_gf {
                // Note: >= is equivalent (exact FP tie never occurs, excluded in mutants.toml)
                max_gf = gf;
                leading = i;
            }
        }
        (max_gf, leading)
    }

    /// Maximum gradient factor across all compartments at a given ambient pressure.
    ///
    /// At surface pressure this equals SurfGF; at current depth it equals GF99.
    fn max_gf_at_pressure(&self, ambient_pressure: f64) -> f64 {
        (0..NUM_COMPARTMENTS)
            .map(|i| self.compartment_gf(i, ambient_pressure))
            .fold(0.0_f64, f64::max)
    }

    /// Gradient factor for a single compartment at the given ambient pressure.
    fn compartment_gf(&self, i: usize, ambient_pressure: f64) -> f64 {
        let p_total = self.p_n2[i] + self.p_he[i];

        // Weighted a, b using Workman/Baker method:
        // a = (a_n2 * p_n2 + a_he * p_he) / p_total  (or fallback to N2-only)
        let (a, b) = if p_total > 1e-10 {
            let a = (A_N2[i] * self.p_n2[i] + A_HE[i] * self.p_he[i]) / p_total;
            let b = (B_N2[i] * self.p_n2[i] + B_HE[i] * self.p_he[i]) / p_total;
            (a, b)
        } else {
            (A_N2[i], B_N2[i])
        };

        // M-value at surface: M_surface = a + P_surface / b
        let m_surface = a + ambient_pressure / b;
        let denom = m_surface - ambient_pressure;

        if denom > 1e-10 {
            // Note: >= is equivalent (denom >> 1e-10 for all Bühlmann constants, excluded in mutants.toml)
            ((p_total - ambient_pressure) / denom) * 100.0
        } else {
            0.0
        }
    }
}

// ============================================================================
// Public API
// ============================================================================

/// Compute Surface Gradient Factor for each sample in a dive profile.
///
/// Uses a Bühlmann ZHL-16C tissue simulation. Assumes the diver starts
/// at surface equilibrium on air.
///
/// For CCR dives, if `SampleInput.ppo2` is set, the simulation uses the actual
/// measured PPO2 to derive effective inspired inert gas fractions (the diluent's
/// He:N2 ratio is preserved). For OC dives (ppo2 = None), gas mix fractions
/// are used directly.
///
/// - `samples` — time-ordered depth/time/gas profile.
/// - `gas_mixes` — gas definitions keyed by `mix_index`. If empty, defaults to air.
/// - `surface_pressure_bar` — ambient surface pressure (defaults to 1.01325 bar).
pub fn compute_surface_gf(
    samples: &[SampleInput],
    gas_mixes: &[GasMixInput],
    surface_pressure_bar: Option<f64>,
) -> Vec<SurfaceGfPoint> {
    if samples.is_empty() {
        return Vec::new();
    }

    let surface_p = surface_pressure_bar.unwrap_or(DEFAULT_SURFACE_PRESSURE);
    let mut tissues = TissueState::surface_equilibrium(surface_p);

    // Build gas mix lookup: index → (fO2, fHe)
    let mut gas_lookup: std::collections::HashMap<i32, (f64, f64)> =
        std::collections::HashMap::new();
    for mix in gas_mixes {
        gas_lookup.insert(mix.mix_index, (mix.o2_fraction, mix.he_fraction));
    }

    // Current gas: start with mix 0 if available, else air
    let default_gas = gas_lookup.get(&0).copied().unwrap_or((AIR_FO2, 0.0));
    let mut current_fo2 = default_gas.0;
    let mut current_fhe = default_gas.1;

    let mut results = Vec::with_capacity(samples.len());

    for (idx, sample) in samples.iter().enumerate() {
        // Compute time delta from previous sample and update tissues
        // using the gas that was being breathed during the interval.
        if idx > 0 {
            let dt_sec = (sample.t_sec - samples[idx - 1].t_sec) as f64;

            // Average depth between this sample and previous (clamp ≥ 0)
            let avg_depth_m =
                ((samples[idx - 1].depth_m as f64 + sample.depth_m as f64) / 2.0).max(0.0);
            let ambient_p = surface_p + avg_depth_m * BAR_PER_METER;

            // Determine effective inert gas fractions.
            // Use the PREVIOUS sample's PPO2, consistent with OC gas switch timing:
            // the interval [samples[idx-1], samples[idx]] is computed with the gas/PPO2
            // that was being breathed at the START of the interval.
            let (fn2, fhe) = if let Some(ppo2) = samples[idx - 1].ppo2 {
                let ppo2 = (ppo2 as f64).clamp(0.0, ambient_p);
                let fo2_eff = ppo2 / ambient_p;
                let f_inert = (1.0 - fo2_eff).max(0.0);
                // Split inert portion using diluent He:N2 ratio
                let dil_n2 = (1.0 - current_fo2 - current_fhe).max(0.0);
                let dil_inert = current_fhe + dil_n2;
                if dil_inert > 1e-10 {
                    // Note: >= is equivalent (gas fractions never produce exact 1e-10, excluded in mutants.toml)
                    (
                        f_inert * dil_n2 / dil_inert,
                        f_inert * current_fhe / dil_inert,
                    )
                } else {
                    (f_inert, 0.0)
                }
            } else {
                // OC: use gas mix fractions directly
                ((1.0 - current_fo2 - current_fhe).max(0.0), current_fhe)
            };

            // Inspired gas partial pressures (accounting for water vapour)
            let p_inspired_n2 = (ambient_p - P_WATER_VAPOR) * fn2;
            let p_inspired_he = (ambient_p - P_WATER_VAPOR) * fhe;

            tissues.update(dt_sec, p_inspired_n2, p_inspired_he);
        }

        // Apply gas switch after tissue update so the previous interval
        // uses the gas that was actually being breathed.
        if let Some(mix_idx) = sample.gasmix_index {
            if let Some(&(fo2, fhe)) = gas_lookup.get(&mix_idx) {
                current_fo2 = fo2;
                current_fhe = fhe;
            }
        }

        let (sgf, leading) = tissues.surface_gf_and_leading(surface_p);

        // GF99: gradient factor at current ambient pressure (depth)
        let current_ambient_p = surface_p + (sample.depth_m as f64).max(0.0) * BAR_PER_METER;
        let gf99 = tissues.max_gf_at_pressure(current_ambient_p);

        results.push(SurfaceGfPoint {
            t_sec: sample.t_sec,
            surface_gf: sgf as f32,
            leading_compartment: leading as u8,
            gf99: gf99 as f32,
        });
    }

    results
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper to build a SampleInput with minimal fields.
    fn sample(t_sec: i32, depth_m: f32, gasmix_index: Option<i32>) -> SampleInput {
        SampleInput {
            t_sec,
            depth_m,
            temp_c: 20.0,
            setpoint_ppo2: None,
            ceiling_m: None,
            gf99: None,
            gasmix_index,
            ppo2: None,
            tts_sec: None,
            ndl_sec: None,
            deco_stop_depth_m: None,
            at_plus_five_tts_min: None,
        }
    }

    #[test]
    fn test_surface_equilibrium() {
        let tissues = TissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE);
        let (sgf, _) = tissues.surface_gf_and_leading(DEFAULT_SURFACE_PRESSURE);
        // At surface equilibrium, SurfGF should be ~0
        assert!(
            sgf.abs() < 1.0,
            "Surface equilibrium SurfGF should be ~0, got {sgf}"
        );
    }

    #[test]
    fn test_surface_equilibrium_exact() {
        // p_n2 = (1.01325 - 0.0627) * 0.7902
        let tissues = TissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE);
        let expected = (DEFAULT_SURFACE_PRESSURE - P_WATER_VAPOR) * AIR_FN2;
        for i in 0..NUM_COMPARTMENTS {
            assert!(
                (tissues.p_n2[i] - expected).abs() < 1e-12,
                "Compartment {i} p_n2 = {}, expected {expected}",
                tissues.p_n2[i]
            );
            assert_eq!(
                tissues.p_he[i], 0.0,
                "He should be 0 at surface equilibrium"
            );
        }
    }

    #[test]
    fn test_tissue_update_n2_exact() {
        // Single compartment 0, one 60s step at 30m on air
        let mut tissues = TissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE);
        let ambient = DEFAULT_SURFACE_PRESSURE + 30.0 * BAR_PER_METER;
        let p_inspired_n2 = (ambient - P_WATER_VAPOR) * AIR_FN2;
        let p_inspired_he = 0.0;

        let p0_before = tissues.p_n2[0];
        tissues.update(60.0, p_inspired_n2, p_inspired_he);

        // Schreiner: p_n2 = p_insp + (p_before - p_insp) * exp(-k * dt)
        let k = (2.0_f64).ln() / (N2_HALF_TIMES[0] * 60.0);
        let expected = p_inspired_n2 + (p0_before - p_inspired_n2) * (-k * 60.0).exp();
        assert!(
            (tissues.p_n2[0] - expected).abs() < 1e-12,
            "N2 compartment 0: got {}, expected {expected}",
            tissues.p_n2[0]
        );
        // He should remain 0 (no He in air)
        assert_eq!(tissues.p_he[0], 0.0);
    }

    #[test]
    fn test_tissue_update_he_exact() {
        // Single compartment 0, one 60s step at 30m on trimix 21/35
        let mut tissues = TissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE);
        let ambient = DEFAULT_SURFACE_PRESSURE + 30.0 * BAR_PER_METER;
        let fo2 = 0.21;
        let fhe = 0.35;
        let fn2 = 1.0 - fo2 - fhe; // 0.44
        let p_inspired_n2 = (ambient - P_WATER_VAPOR) * fn2;
        let p_inspired_he = (ambient - P_WATER_VAPOR) * fhe;

        let p_n2_before = tissues.p_n2[0];
        let p_he_before = tissues.p_he[0]; // 0.0

        tissues.update(60.0, p_inspired_n2, p_inspired_he);

        // N2
        let k_n2 = (2.0_f64).ln() / (N2_HALF_TIMES[0] * 60.0);
        let expected_n2 = p_inspired_n2 + (p_n2_before - p_inspired_n2) * (-k_n2 * 60.0).exp();
        assert!(
            (tissues.p_n2[0] - expected_n2).abs() < 1e-12,
            "N2: got {}, expected {expected_n2}",
            tissues.p_n2[0]
        );

        // He
        let k_he = (2.0_f64).ln() / (HE_HALF_TIMES[0] * 60.0);
        let expected_he = p_inspired_he + (p_he_before - p_inspired_he) * (-k_he * 60.0).exp();
        assert!(
            (tissues.p_he[0] - expected_he).abs() < 1e-12,
            "He: got {}, expected {expected_he}",
            tissues.p_he[0]
        );
        // He should be > 0 after trimix exposure
        assert!(tissues.p_he[0] > 0.0);
    }

    #[test]
    fn test_compartment_gf_exact() {
        // Manually set tissue state, compute expected GF for compartment 0
        let mut tissues = TissueState {
            p_n2: [0.0; NUM_COMPARTMENTS],
            p_he: [0.0; NUM_COMPARTMENTS],
        };
        // Set compartment 0 to a known supersaturated state
        tissues.p_n2[0] = 3.0; // bar (supersaturated at surface)
        tissues.p_he[0] = 0.5;

        let p_total = 3.0 + 0.5; // 3.5
        let a = (A_N2[0] * 3.0 + A_HE[0] * 0.5) / p_total;
        let b = (B_N2[0] * 3.0 + B_HE[0] * 0.5) / p_total;
        let m_surface = a + DEFAULT_SURFACE_PRESSURE / b;
        let denom = m_surface - DEFAULT_SURFACE_PRESSURE;
        let expected_gf = ((p_total - DEFAULT_SURFACE_PRESSURE) / denom) * 100.0;

        let gf = tissues.compartment_gf(0, DEFAULT_SURFACE_PRESSURE);
        assert!(
            (gf - expected_gf).abs() < 1e-10,
            "GF: got {gf}, expected {expected_gf}"
        );
    }

    #[test]
    fn test_surface_gf_leading_tiebreak() {
        // Two compartments with equal GF → first one should win (catches > → >=)
        let mut tissues = TissueState {
            p_n2: [0.0; NUM_COMPARTMENTS],
            p_he: [0.0; NUM_COMPARTMENTS],
        };
        // Set compartments 0 and 1 to produce the same GF
        tissues.p_n2[0] = 2.0;
        let gf0 = tissues.compartment_gf(0, DEFAULT_SURFACE_PRESSURE);

        // Find the p_n2 for compartment 1 that gives the same GF
        // GF = (p - P_s) / (a + P_s/b - P_s) * 100
        // Solving for p: p = GF/100 * (a1 + Ps/b1 - Ps) + Ps
        let m1 = A_N2[1] + DEFAULT_SURFACE_PRESSURE / B_N2[1];
        let denom1 = m1 - DEFAULT_SURFACE_PRESSURE;
        let p_needed = (gf0 / 100.0) * denom1 + DEFAULT_SURFACE_PRESSURE;
        tissues.p_n2[1] = p_needed;

        let gf1 = tissues.compartment_gf(1, DEFAULT_SURFACE_PRESSURE);
        assert!(
            (gf0 - gf1).abs() < 1e-10,
            "GFs should be equal: {gf0} vs {gf1}"
        );

        let (_, leading) = tissues.surface_gf_and_leading(DEFAULT_SURFACE_PRESSURE);
        assert_eq!(leading, 0, "First compartment should win on tie");
    }

    #[test]
    fn test_compartment_gf_p_total_at_threshold() {
        // p_total exactly at 1e-10 boundary. With `>`: use N2-only fallback.
        // With `>=`: use weighted average. Catches line 167 mutation.
        let mut tissues = TissueState {
            p_n2: [0.0; NUM_COMPARTMENTS],
            p_he: [0.0; NUM_COMPARTMENTS],
        };
        // Set compartment 0 so p_total = 1e-10 exactly
        tissues.p_n2[0] = 5e-11;
        tissues.p_he[0] = 5e-11;
        let p_total = tissues.p_n2[0] + tissues.p_he[0];
        // 5e-11 + 5e-11 should equal 1e-10 exactly (exact doubling)
        assert_eq!(p_total, 1e-10);

        // With > (original): 1e-10 > 1e-10 = false → N2-only: a=A_N2[0], b=B_N2[0]
        // With >= (mutant): 1e-10 >= 1e-10 = true → weighted: a=(A_N2*0.5+A_HE*0.5), etc.
        // These should produce different GFs since A_N2[0] ≠ A_HE[0].
        let gf_actual = tissues.compartment_gf(0, DEFAULT_SURFACE_PRESSURE);

        // Compute N2-only (what the code should do with >)
        let a_n2_only = A_N2[0];
        let b_n2_only = B_N2[0];
        let m_surface_n2 = a_n2_only + DEFAULT_SURFACE_PRESSURE / b_n2_only;
        let denom_n2 = m_surface_n2 - DEFAULT_SURFACE_PRESSURE;
        let expected_n2_only = ((p_total - DEFAULT_SURFACE_PRESSURE) / denom_n2) * 100.0;

        // Verify original path (N2-only) is used
        assert!(
            (gf_actual - expected_n2_only).abs() < 1e-6,
            "Should use N2-only path: got {gf_actual}, expected {expected_n2_only}"
        );

        // Compute weighted (what the mutant would do with >=)
        let a_weighted = (A_N2[0] * 5e-11 + A_HE[0] * 5e-11) / 1e-10;
        let b_weighted = (B_N2[0] * 5e-11 + B_HE[0] * 5e-11) / 1e-10;
        let m_surface_w = a_weighted + DEFAULT_SURFACE_PRESSURE / b_weighted;
        let denom_w = m_surface_w - DEFAULT_SURFACE_PRESSURE;
        let expected_weighted = ((p_total - DEFAULT_SURFACE_PRESSURE) / denom_w) * 100.0;

        // The two paths must produce different results
        assert!(
            (expected_n2_only - expected_weighted).abs() > 1e-6,
            "N2-only and weighted should differ to detect mutation"
        );
    }

    #[test]
    fn test_compartment_gf_denom_at_threshold() {
        // denom exactly at 1e-10 boundary. With `>`: compute GF.
        // With `>=`: also compute GF (1e-10 >= 1e-10 = true). Same result.
        // Actually, with `>`: 1e-10 > 1e-10 = false → return 0.0.
        // With `>=`: 1e-10 >= 1e-10 = true → compute GF.
        // So setting denom = 1e-10 exactly will differentiate the two.
        //
        // denom = m_surface - ambient = (a + ambient/b) - ambient = a + ambient*(1/b - 1)
        // We need: a + ambient*(1/b - 1) = 1e-10
        // Since this is hard to construct for real compartments, we use a tissue
        // state where p_total just barely exceeds ambient for a specific compartment.
        let mut tissues = TissueState {
            p_n2: [0.0; NUM_COMPARTMENTS],
            p_he: [0.0; NUM_COMPARTMENTS],
        };

        // For compartment 0: a=1.1696, b=0.5578
        // m_surface = 1.1696 + 1.01325/0.5578 = 1.1696 + 1.81611... = 2.98571...
        // denom = 2.98571... - 1.01325 = 1.97246...
        // This is much bigger than 1e-10. Need to find compartment/ambient combo.
        //
        // We need m_surface very close to ambient: a + P/b ≈ P
        // → a ≈ P*(1 - 1/b) = P*(b-1)/b
        // For b=0.5578: P*(b-1)/b = P*(-0.4422/0.5578) < 0 → impossible for a > 0.
        //
        // Bühlmann constants always give denom >> 1e-10 for real pressures,
        // so this mutation is genuinely equivalent.
        // Just verify GF is computable for normal inputs.
        tissues.p_n2[0] = DEFAULT_SURFACE_PRESSURE; // exactly at ambient
        let gf = tissues.compartment_gf(0, DEFAULT_SURFACE_PRESSURE);
        // p_total = ambient → gf = (ambient - ambient) / denom * 100 = 0
        assert!(gf.abs() < 1e-10, "At ambient pressure, GF should be 0");
    }

    #[test]
    fn test_tissue_update_zero_dt() {
        // dt <= 0 should be a no-op
        let mut tissues = TissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE);
        let before = tissues.p_n2[0];
        tissues.update(0.0, 5.0, 1.0);
        assert_eq!(tissues.p_n2[0], before);
        assert_eq!(tissues.p_he[0], 0.0);

        tissues.update(-10.0, 5.0, 1.0);
        assert_eq!(tissues.p_n2[0], before);
    }

    #[test]
    fn test_ccr_inert_fraction_exact() {
        // At 60m, ambient ≈ 7.08 bar. PPO2=1.2 → fO2_eff = 1.2/7.08
        // With diluent 10/50: dil_n2=0.40, dil_he=0.50, dil_inert=0.90
        // f_inert = 1 - fO2_eff. fn2 = f_inert * 0.40/0.90, fhe = f_inert * 0.50/0.90
        let mixes = vec![GasMixInput {
            mix_index: 0,
            o2_fraction: 0.10,
            he_fraction: 0.50,
        }];

        // 2 samples: surface at 0m, then at 60m with PPO2=1.2
        let samples = vec![
            SampleInput {
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
            },
            SampleInput {
                t_sec: 60,
                depth_m: 60.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: Some(1.2),
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];

        let result = compute_surface_gf(&samples, &mixes, None);
        assert_eq!(result.len(), 2);
        // First sample at surface: no tissue update, just equilibrium GF
        assert!(result[0].surface_gf.abs() < 1.0);
        // Second sample at 60m: should have positive GF from loading
        assert!(result[1].surface_gf > 0.0);
        // Verify leading compartment is valid
        assert!(result[1].leading_compartment < 16);
    }

    #[test]
    fn test_trimix_sgf_exact() {
        // Known profile: 60m for 20 min on trimix 21/35. Compute manually.
        let mixes = vec![GasMixInput {
            mix_index: 0,
            o2_fraction: 0.21,
            he_fraction: 0.35,
        }];
        let fn2 = 1.0 - 0.21 - 0.35; // 0.44

        let mut samples = vec![sample(0, 0.0, Some(0))];
        samples.push(sample(60, 60.0, Some(0)));
        for i in 2..=20 {
            samples.push(sample(i * 60, 60.0, Some(0)));
        }

        let result = compute_surface_gf(&samples, &mixes, None);

        // Simulate manually for the final point
        let surface_p = DEFAULT_SURFACE_PRESSURE;
        let mut manual_tissues = TissueState::surface_equilibrium(surface_p);

        // Interval 0→1: avg depth = 30m
        let avg_depth = 30.0;
        let ambient = surface_p + avg_depth * BAR_PER_METER;
        let p_n2 = (ambient - P_WATER_VAPOR) * fn2;
        let p_he = (ambient - P_WATER_VAPOR) * 0.35;
        manual_tissues.update(60.0, p_n2, p_he);

        // Intervals 1→2 through 19→20: all at 60m
        for _ in 1..20 {
            let ambient_60 = surface_p + 60.0 * BAR_PER_METER;
            let p_n2_60 = (ambient_60 - P_WATER_VAPOR) * fn2;
            let p_he_60 = (ambient_60 - P_WATER_VAPOR) * 0.35;
            manual_tissues.update(60.0, p_n2_60, p_he_60);
        }

        let (expected_gf, expected_leading) = manual_tissues.surface_gf_and_leading(surface_p);
        let final_pt = result.last().unwrap();

        assert!(
            (final_pt.surface_gf as f64 - expected_gf).abs() < 0.1,
            "SurfGF: got {}, expected {expected_gf}",
            final_pt.surface_gf
        );
        assert_eq!(final_pt.leading_compartment, expected_leading as u8);
    }

    #[test]
    fn test_ccr_tissue_loading_exact() {
        // CCR at 30m, diluent air, PPO2=1.3. Manually compute expected tissue state.
        // This catches mutations in lines 245-255 (inert fraction computation).
        let fo2 = AIR_FO2;
        let fhe = 0.0;
        let surface_p = DEFAULT_SURFACE_PRESSURE;

        let mixes = vec![GasMixInput {
            mix_index: 0,
            o2_fraction: fo2,
            he_fraction: fhe,
        }];

        // 3 samples: surface (PPO2=0.7), 30m (PPO2=1.3), 30m (PPO2=1.3)
        let ccr_samples = vec![
            SampleInput {
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
            },
            SampleInput {
                t_sec: 60,
                depth_m: 30.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: Some(1.3),
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 120,
                depth_m: 30.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: Some(1.3),
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];

        let result = compute_surface_gf(&ccr_samples, &mixes, None);

        // Manually compute the tissue state
        let mut manual = TissueState::surface_equilibrium(surface_p);

        // Interval 0→1: prev ppo2=0.7, avg depth=(0+30)/2=15m
        let avg_d1 = 15.0;
        let ambient1 = surface_p + avg_d1 * BAR_PER_METER;
        let ppo2_1 = (0.7_f64).clamp(0.0, ambient1);
        let fo2_eff1 = ppo2_1 / ambient1;
        let f_inert1 = (1.0 - fo2_eff1).max(0.0);
        let dil_n2 = (1.0 - fo2 - fhe).max(0.0); // N2 fraction of diluent
        let dil_inert = fhe + dil_n2;
        let fn2_1 = f_inert1 * dil_n2 / dil_inert;
        let fhe_1 = f_inert1 * fhe / dil_inert; // 0.0
        let p_n2_1 = (ambient1 - P_WATER_VAPOR) * fn2_1;
        let p_he_1 = (ambient1 - P_WATER_VAPOR) * fhe_1;
        manual.update(60.0, p_n2_1, p_he_1);

        // Interval 1→2: prev ppo2=1.3, avg depth=(30+30)/2=30m
        let avg_d2 = 30.0;
        let ambient2 = surface_p + avg_d2 * BAR_PER_METER;
        let ppo2_2 = (1.3_f64).clamp(0.0, ambient2);
        let fo2_eff2 = ppo2_2 / ambient2;
        let f_inert2 = (1.0 - fo2_eff2).max(0.0);
        let fn2_2 = f_inert2 * dil_n2 / dil_inert;
        let fhe_2 = f_inert2 * fhe / dil_inert;
        let p_n2_2 = (ambient2 - P_WATER_VAPOR) * fn2_2;
        let p_he_2 = (ambient2 - P_WATER_VAPOR) * fhe_2;
        manual.update(60.0, p_n2_2, p_he_2);

        let (expected_gf, expected_leading) = manual.surface_gf_and_leading(surface_p);
        let pt = &result[2];
        assert!(
            (pt.surface_gf as f64 - expected_gf).abs() < 0.01,
            "CCR SurfGF mismatch: got {}, expected {expected_gf}",
            pt.surface_gf
        );
        assert_eq!(pt.leading_compartment, expected_leading as u8);
    }

    #[test]
    fn test_ccr_trimix_diluent_exact() {
        // CCR at 60m, trimix diluent 10/50 (10% O2, 50% He, 40% N2), PPO2=1.2
        // This specifically tests the He:N2 ratio splitting in lines 254-255.
        let fo2 = 0.10;
        let fhe = 0.50;
        let surface_p = DEFAULT_SURFACE_PRESSURE;

        let mixes = vec![GasMixInput {
            mix_index: 0,
            o2_fraction: fo2,
            he_fraction: fhe,
        }];

        let samples = vec![
            SampleInput {
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
            },
            SampleInput {
                t_sec: 60,
                depth_m: 60.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: Some(1.2),
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 660,
                depth_m: 60.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: Some(1.2),
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];

        let result = compute_surface_gf(&samples, &mixes, None);

        // Manual simulation
        let mut manual = TissueState::surface_equilibrium(surface_p);

        // Interval 0→1: prev ppo2=0.7, avg depth=30m
        let ambient1 = surface_p + 30.0 * BAR_PER_METER;
        let ppo2_clamped1 = (0.7_f64).clamp(0.0, ambient1);
        let fo2_eff1 = ppo2_clamped1 / ambient1;
        let f_inert1 = (1.0 - fo2_eff1).max(0.0);
        let dil_n2 = (1.0 - fo2 - fhe).max(0.0); // 0.40
        let dil_inert = fhe + dil_n2; // 0.90
        let fn2_1 = f_inert1 * dil_n2 / dil_inert;
        let fhe_1 = f_inert1 * fhe / dil_inert;
        manual.update(
            60.0,
            (ambient1 - P_WATER_VAPOR) * fn2_1,
            (ambient1 - P_WATER_VAPOR) * fhe_1,
        );

        // Interval 1→2: prev ppo2=1.2, avg depth=60m, 600s
        let ambient2 = surface_p + 60.0 * BAR_PER_METER;
        let ppo2_clamped2 = (1.2_f64).clamp(0.0, ambient2);
        let fo2_eff2 = ppo2_clamped2 / ambient2;
        let f_inert2 = (1.0 - fo2_eff2).max(0.0);
        let fn2_2 = f_inert2 * dil_n2 / dil_inert;
        let fhe_2 = f_inert2 * fhe / dil_inert;
        manual.update(
            600.0,
            (ambient2 - P_WATER_VAPOR) * fn2_2,
            (ambient2 - P_WATER_VAPOR) * fhe_2,
        );

        let (expected_gf, expected_leading) = manual.surface_gf_and_leading(surface_p);
        let pt = result.last().unwrap();
        assert!(
            (pt.surface_gf as f64 - expected_gf).abs() < 0.01,
            "CCR trimix SurfGF: got {}, expected {expected_gf}",
            pt.surface_gf
        );
        assert_eq!(pt.leading_compartment, expected_leading as u8);

        // Verify He loading happened (fn2 ≠ fhe, both > 0)
        assert!(fhe_2 > 0.0, "He fraction should be positive");
        assert!(fn2_2 > 0.0, "N2 fraction should be positive");
        assert!(
            fhe_2 > fn2_2,
            "He fraction should exceed N2 for 10/50 diluent"
        );
    }

    #[test]
    fn test_ccr_pure_o2_diluent() {
        // Diluent with fO2=1.0, fHe=0.0 → dil_n2 = 0, dil_inert = 0.
        // With `dil_inert > 1e-10` (original): false → use (f_inert, 0.0)
        // With `>= 1e-10` (mutant): still false (0 < 1e-10), same result.
        // So for EXACTLY 0.0, both paths agree. Need dil_inert = 1e-10.
        //
        // dil_inert = fhe + (1 - fo2 - fhe). If fo2 = 1.0 - 1e-10, fhe = 0:
        //   dil_n2 = 1.0 - (1.0 - 1e-10) - 0 = 1e-10 (may have fp error)
        //   dil_inert = 0 + 1e-10 = 1e-10
        //
        // But 1.0 - (1.0 - 1e-10) in IEEE 754 f64: 1e-10 is exact if we can
        // guarantee the subtraction. Actually (1.0 - 1e-10) rounds to
        // 0.9999999999 in f64, and 1.0 - 0.9999999999... gives back 1e-10.
        // This is NOT guaranteed for arbitrary values, but 1e-10 ≈ 2^-33.2
        // which has enough precision in the f64 mantissa.
        //
        // For the test, we verify the pure O2 case works (dil_inert = 0).
        let mixes = vec![GasMixInput {
            mix_index: 0,
            o2_fraction: 1.0,
            he_fraction: 0.0,
        }];

        let samples = vec![
            SampleInput {
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
            },
            SampleInput {
                t_sec: 60,
                depth_m: 30.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: Some(1.3),
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 600,
                depth_m: 30.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: Some(1.3),
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];

        let result = compute_surface_gf(&samples, &mixes, None);
        assert_eq!(result.len(), 3);

        // With pure O2 diluent and PPO2=1.3 at 30m:
        // dil_inert = 0, so we use the (f_inert, 0.0) fallback path.
        // f_inert = 1 - 1.3/4.053 ≈ 0.679, fn2 = f_inert, fhe = 0.
        // This means all inert gas is N2.
        // Manually compute:
        let surface_p = DEFAULT_SURFACE_PRESSURE;
        let mut manual = TissueState::surface_equilibrium(surface_p);

        // Interval 0→1: prev ppo2=0.7, avg depth=15m
        let ambient1 = surface_p + 15.0 * BAR_PER_METER;
        let ppo2_1 = 0.7_f64.clamp(0.0, ambient1);
        let f_inert1 = (1.0 - ppo2_1 / ambient1).max(0.0);
        // dil_inert = 0, so fn2 = f_inert, fhe = 0
        manual.update(60.0, (ambient1 - P_WATER_VAPOR) * f_inert1, 0.0);

        // Interval 1→2: prev ppo2=1.3, avg depth=30m, dt=540s
        let ambient2 = surface_p + 30.0 * BAR_PER_METER;
        let ppo2_2 = 1.3_f64.clamp(0.0, ambient2);
        let f_inert2 = (1.0 - ppo2_2 / ambient2).max(0.0);
        manual.update(540.0, (ambient2 - P_WATER_VAPOR) * f_inert2, 0.0);

        let (expected_gf, _) = manual.surface_gf_and_leading(surface_p);
        let pt = result.last().unwrap();
        assert!(
            (pt.surface_gf as f64 - expected_gf).abs() < 0.01,
            "Pure O2 diluent SurfGF: got {}, expected {expected_gf}",
            pt.surface_gf
        );
    }

    #[test]
    fn test_ccr_different_prev_ppo2() {
        // Test that we use the PREVIOUS sample's PPO2, not current (line 245).
        // Two profiles: identical except PPO2 on sample[0] differs.
        // If mutation changes idx-1 to idx, the results would be the same.
        let mixes = vec![GasMixInput {
            mix_index: 0,
            o2_fraction: 0.21,
            he_fraction: 0.0,
        }];

        // Profile A: low PPO2 on sample 0, high on sample 1
        let samples_a = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: Some(0.5),
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 300,
                depth_m: 30.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: Some(1.3),
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];

        // Profile B: high PPO2 on sample 0
        let samples_b = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: Some(1.0),
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 300,
                depth_m: 30.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: Some(1.3),
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];

        let result_a = compute_surface_gf(&samples_a, &mixes, None);
        let result_b = compute_surface_gf(&samples_b, &mixes, None);

        // The first interval uses sample[0].ppo2 (the PREVIOUS).
        // Profile A uses PPO2=0.5, B uses PPO2=1.0. These should differ.
        let gf_a = result_a[1].surface_gf;
        let gf_b = result_b[1].surface_gf;
        assert!(
            (gf_a - gf_b).abs() > 0.5,
            "Different prev PPO2 should produce different SurfGF: A={gf_a}, B={gf_b}"
        );
    }

    #[test]
    fn test_surface_samples_zero_gf() {
        // Stay at 0m for 10 minutes — SurfGF should stay near 0
        let samples: Vec<SampleInput> = (0..=10).map(|i| sample(i * 60, 0.0, None)).collect();

        let result = compute_surface_gf(&samples, &[], None);
        assert_eq!(result.len(), 11);
        for pt in &result {
            assert!(
                pt.surface_gf.abs() < 1.0,
                "At surface, SurfGF should be ~0, got {} at t={}",
                pt.surface_gf,
                pt.t_sec
            );
        }
    }

    #[test]
    fn test_square_profile_30m_30min_air() {
        // Instant descent to 30m, stay 30 min, then ascend
        let mut samples = vec![sample(0, 0.0, None)];
        // Descent in 1 minute
        samples.push(sample(60, 30.0, None));
        // Bottom for 30 minutes (every minute)
        for i in 2..=31 {
            samples.push(sample(i * 60, 30.0, None));
        }
        // Ascent in 3 minutes
        samples.push(sample(32 * 60, 20.0, None));
        samples.push(sample(33 * 60, 10.0, None));
        samples.push(sample(34 * 60, 0.0, None));

        let result = compute_surface_gf(&samples, &[], None);
        assert_eq!(result.len(), samples.len());

        // SurfGF should increase during bottom time
        let bottom_start_gf = result[2].surface_gf;
        let bottom_end_gf = result[31].surface_gf;
        assert!(
            bottom_end_gf > bottom_start_gf,
            "SurfGF should increase during bottom: start={bottom_start_gf}, end={bottom_end_gf}"
        );

        // Final SurfGF at end of 30 min at 30m should be significant.
        // SurfGF > 100% is expected — it means deco obligation.
        assert!(
            bottom_end_gf > 80.0,
            "30m/30min air SurfGF should be >80%, got {bottom_end_gf}"
        );
    }

    #[test]
    fn test_trimix_21_35() {
        // 60m for 20 minutes on trimix 21/35 (21% O2, 35% He, 44% N2)
        let mixes = vec![GasMixInput {
            mix_index: 0,
            o2_fraction: 0.21,
            he_fraction: 0.35,
        }];

        let mut samples = vec![sample(0, 0.0, Some(0))];
        samples.push(sample(60, 60.0, Some(0)));
        for i in 2..=21 {
            samples.push(sample(i * 60, 60.0, Some(0)));
        }

        let result = compute_surface_gf(&samples, &mixes, None);

        // He loads faster — SurfGF should be substantial
        let final_gf = result.last().unwrap().surface_gf;
        assert!(
            final_gf > 80.0,
            "60m/20min trimix 21/35 should produce high SurfGF, got {final_gf}"
        );
    }

    #[test]
    fn test_gas_switch() {
        // Bottom on trimix 21/35, switch to EAN50 at 21m
        let mixes = vec![
            GasMixInput {
                mix_index: 0,
                o2_fraction: 0.21,
                he_fraction: 0.35,
            },
            GasMixInput {
                mix_index: 1,
                o2_fraction: 0.50,
                he_fraction: 0.0,
            },
        ];

        let mut samples = vec![sample(0, 0.0, Some(0))];
        // Descent + bottom at 45m for 20 min
        samples.push(sample(60, 45.0, Some(0)));
        for i in 2..=20 {
            samples.push(sample(i * 60, 45.0, Some(0)));
        }
        // Ascend to 21m, switch to EAN50
        samples.push(sample(21 * 60, 21.0, Some(1)));
        // Deco stop at 21m for 5 min
        for i in 22..=26 {
            samples.push(sample(i * 60, 21.0, Some(1)));
        }

        let result = compute_surface_gf(&samples, &mixes, None);

        // SurfGF should peak around the gas switch then decrease
        let gf_at_switch = result[21].surface_gf;
        let gf_end_deco = result.last().unwrap().surface_gf;
        assert!(
            gf_end_deco < gf_at_switch,
            "SurfGF should decrease after switching to EAN50: at_switch={gf_at_switch}, end={gf_end_deco}"
        );
    }

    #[test]
    fn test_empty_samples() {
        let result = compute_surface_gf(&[], &[], None);
        assert!(result.is_empty());
    }

    #[test]
    fn test_single_sample() {
        let samples = vec![sample(0, 0.0, None)];
        let result = compute_surface_gf(&samples, &[], None);
        assert_eq!(result.len(), 1);
        assert!(
            result[0].surface_gf.abs() < 1.0,
            "Single surface sample SurfGF should be ~0, got {}",
            result[0].surface_gf
        );
    }

    #[test]
    fn test_no_gas_mix_defaults_to_air() {
        // No mixes provided — should use air
        let samples = vec![
            sample(0, 0.0, None),
            sample(60, 30.0, None),
            sample(20 * 60, 30.0, None),
        ];

        let result_no_mix = compute_surface_gf(&samples, &[], None);

        let air_mix = vec![GasMixInput {
            mix_index: 0,
            o2_fraction: AIR_FO2,
            he_fraction: 0.0,
        }];
        // Same samples but with explicit gasmix_index
        let samples_with_idx: Vec<SampleInput> = samples
            .iter()
            .map(|s| SampleInput {
                gasmix_index: Some(0),
                ..s.clone()
            })
            .collect();
        let result_air = compute_surface_gf(&samples_with_idx, &air_mix, None);

        // Should produce identical results
        assert_eq!(result_no_mix.len(), result_air.len());
        for (a, b) in result_no_mix.iter().zip(result_air.iter()) {
            assert!(
                (a.surface_gf - b.surface_gf).abs() < 0.01,
                "Default air should match explicit air: {} vs {}",
                a.surface_gf,
                b.surface_gf
            );
        }
    }

    #[test]
    fn test_custom_surface_pressure() {
        // Altitude dive at ~1800m (0.82 bar) vs sea level
        let samples = vec![
            sample(0, 0.0, None),
            sample(60, 30.0, None),
            sample(20 * 60, 30.0, None),
        ];

        let result_sea = compute_surface_gf(&samples, &[], None);
        let result_alt = compute_surface_gf(&samples, &[], Some(0.82));

        let gf_sea = result_sea.last().unwrap().surface_gf;
        let gf_alt = result_alt.last().unwrap().surface_gf;

        assert!(
            gf_alt > gf_sea,
            "Altitude (0.82 bar) should produce higher SurfGF: altitude={gf_alt}, sea={gf_sea}"
        );
    }

    #[test]
    fn test_numerical_precision_long_dive() {
        // Very long exposure: 1000 minutes at 10m
        let mut samples = vec![sample(0, 0.0, None)];
        samples.push(sample(60, 10.0, None));
        for i in 2..=1000 {
            samples.push(sample(i * 60, 10.0, None));
        }

        let result = compute_surface_gf(&samples, &[], None);

        // All values should be finite
        for pt in &result {
            assert!(pt.surface_gf.is_finite(), "SurfGF must be finite");
            assert!(
                pt.leading_compartment < 16,
                "Leading compartment must be 0-15"
            );
        }

        // SurfGF change should slow as tissues approach equilibrium.
        // Early vs late rate-of-change should differ.
        let early_delta = (result[100].surface_gf - result[50].surface_gf).abs();
        let late_delta = (result[1000].surface_gf - result[950].surface_gf).abs();
        assert!(
            late_delta < early_delta,
            "Late delta ({late_delta}) should be less than early delta ({early_delta})"
        );
    }

    #[test]
    fn test_known_result_30m_20min_air() {
        // 30m for 20 min on air — cross-check against published table expectations.
        // Expected SurfGF at end of bottom time: ~100-120%.
        // Values > 100% are normal — they indicate deco obligation.
        let mut samples = vec![sample(0, 0.0, None)];
        samples.push(sample(60, 30.0, None));
        for i in 2..=20 {
            samples.push(sample(i * 60, 30.0, None));
        }

        let result = compute_surface_gf(&samples, &[], None);
        let final_gf = result.last().unwrap().surface_gf;

        assert!(
            (80.0..=130.0).contains(&final_gf),
            "30m/20min air SurfGF should be ~100-120%, got {final_gf}"
        );
    }

    #[test]
    fn test_ccr_ppo2_reduces_inert_loading() {
        // CCR dive at 60m/20min on diluent 10/50 (10% O2, 50% He).
        //
        // Real-world CCR pattern: two setpoints configured.
        //   - Setpoint Low  ≈ 0.7 bar (surface + descent, auto-switch on shallow ascent)
        //   - Setpoint High ≈ 1.2 bar (bottom, switched manually during/after descent)
        //
        // At 60m, ambient ≈ 7.08 bar, so fO2_eff = 1.2/7.08 ≈ 0.169.
        // The effective inert fraction is ~0.831, much higher O2 than the diluent's 10%.
        // OC on the same diluent would have fO2 = 0.10, so inert fraction = 0.90.
        // CCR SurfGF should be lower than OC SurfGF.
        let mixes = vec![GasMixInput {
            mix_index: 0,
            o2_fraction: 0.10,
            he_fraction: 0.50,
        }];

        // Build CCR samples: setpoint low (0.7) at surface, setpoint high (1.2) at depth
        let ccr_samples: Vec<SampleInput> = {
            let mut s = vec![SampleInput {
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
            s.push(SampleInput {
                t_sec: 60,
                depth_m: 60.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: Some(1.2),
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            });
            for i in 2..=20 {
                s.push(SampleInput {
                    t_sec: i * 60,
                    depth_m: 60.0,
                    temp_c: 20.0,
                    setpoint_ppo2: None,
                    ceiling_m: None,
                    gf99: None,
                    gasmix_index: Some(0),
                    ppo2: Some(1.2),
                    tts_sec: None,
                    ndl_sec: None,
                    deco_stop_depth_m: None,
                    at_plus_five_tts_min: None,
                });
            }
            s
        };

        // Build OC samples (no ppo2)
        let oc_samples: Vec<SampleInput> = {
            let mut s = vec![sample(0, 0.0, Some(0))];
            s.push(sample(60, 60.0, Some(0)));
            for i in 2..=20 {
                s.push(sample(i * 60, 60.0, Some(0)));
            }
            s
        };

        let ccr_result = compute_surface_gf(&ccr_samples, &mixes, None);
        let oc_result = compute_surface_gf(&oc_samples, &mixes, None);

        let ccr_final = ccr_result.last().unwrap().surface_gf;
        let oc_final = oc_result.last().unwrap().surface_gf;

        assert!(
            ccr_final < oc_final,
            "CCR SurfGF ({ccr_final}) should be lower than OC SurfGF ({oc_final}) \
             because setpoint high (1.2 bar) reduces effective inert gas loading vs OC diluent"
        );

        // CCR SurfGF should still be significant at 60m/20min
        assert!(
            ccr_final > 30.0,
            "CCR 60m/20min SurfGF should be meaningful, got {ccr_final}"
        );
    }

    #[test]
    fn test_gf99_at_surface_is_near_zero() {
        // Equilibrium tissues at surface → GF99 at surface pressure ≈ 0
        let tissues = TissueState::surface_equilibrium(DEFAULT_SURFACE_PRESSURE);
        let gf99 = tissues.max_gf_at_pressure(DEFAULT_SURFACE_PRESSURE);
        assert!(
            gf99.abs() < 1.0,
            "GF99 at surface equilibrium should be ~0, got {gf99}"
        );
    }

    #[test]
    fn test_gf99_less_than_surface_gf() {
        // During ascent, GF99 should be positive but less than SurfGF,
        // because tissues are supersaturated relative to current ambient
        // but even more supersaturated relative to surface.
        let mut samples = vec![sample(0, 0.0, None)];
        samples.push(sample(60, 30.0, None));
        for i in 2..=20 {
            samples.push(sample(i * 60, 30.0, None));
        }
        // Ascend to 6m — tissues loaded from 30m are now supersaturated
        samples.push(sample(21 * 60, 6.0, None));

        let result = compute_surface_gf(&samples, &[], None);

        // At constant depth, GF99 ≤ SurfGF (tissues undersaturated at current ambient)
        let at_depth = &result[10];
        assert!(
            at_depth.gf99 <= at_depth.surface_gf,
            "GF99 ({}) should be ≤ SurfGF ({}) at depth",
            at_depth.gf99,
            at_depth.surface_gf
        );

        // During ascent, GF99 is positive and less than SurfGF
        let during_ascent = result.last().unwrap();
        assert!(
            during_ascent.gf99 > 0.0,
            "GF99 should be positive during ascent, got {}",
            during_ascent.gf99
        );
        assert!(
            during_ascent.gf99 < during_ascent.surface_gf,
            "GF99 ({}) should be < SurfGF ({}) during ascent",
            during_ascent.gf99,
            during_ascent.surface_gf
        );
    }

    #[test]
    fn test_gf99_field_in_output() {
        // Verify the gf99 field is populated for every sample in compute_surface_gf.
        // Profile: descend to 30m, stay, then ascend — GF99 becomes positive on ascent.
        let mut samples = vec![sample(0, 0.0, None)];
        samples.push(sample(60, 30.0, None));
        for i in 2..=10 {
            samples.push(sample(i * 60, 30.0, None));
        }
        // Ascend to surface
        samples.push(sample(11 * 60, 0.0, None));

        let result = compute_surface_gf(&samples, &[], None);
        assert_eq!(result.len(), samples.len());

        for pt in &result {
            assert!(pt.gf99.is_finite(), "GF99 must be finite at t={}", pt.t_sec);
        }

        // At surface (t=0), GF99 should be near 0
        let gf99_at_surface = result[0].gf99;
        assert!(
            gf99_at_surface.abs() < 1.0,
            "GF99 at surface should be ~0, got {gf99_at_surface}"
        );

        // After ascent to surface, GF99 = SurfGF (ambient = surface pressure)
        let last = result.last().unwrap();
        assert!(
            last.gf99 > 0.0,
            "GF99 should be positive after ascent to surface, got {}",
            last.gf99
        );
        assert!(
            (last.gf99 - last.surface_gf).abs() < 0.1,
            "At surface, GF99 ({}) should equal SurfGF ({})",
            last.gf99,
            last.surface_gf
        );
    }
}
