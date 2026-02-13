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
                max_gf = gf;
                leading = i;
            }
        }
        (max_gf, leading)
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
/// **Note:** Assumes open-circuit gas fractions. CCR `setpoint_ppo2` is not yet
/// used to derive effective inspired fractions — a future enhancement.
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

            // Inspired gas partial pressures (accounting for water vapour)
            let fn2 = (1.0 - current_fo2 - current_fhe).max(0.0);
            let p_inspired_n2 = (ambient_p - P_WATER_VAPOR) * fn2;
            let p_inspired_he = (ambient_p - P_WATER_VAPOR) * current_fhe;

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

        results.push(SurfaceGfPoint {
            t_sec: sample.t_sec,
            surface_gf: sgf as f32,
            leading_compartment: leading as u8,
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
}
