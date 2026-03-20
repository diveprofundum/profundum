//! Shared physics constants and helpers used by both the existing Bühlmann
//! SurfGF computation and the new deco engine.

// ============================================================================
// Physical Constants
// ============================================================================

/// Water vapour pressure in the lungs (bar), at 37 deg C.
pub(crate) const P_WATER_VAPOR: f64 = 0.0627;

/// Pressure increase per metre of seawater (bar/m).
/// 1 atm / 10 msw = 1.01325 / 10.0
pub(crate) const BAR_PER_METER: f64 = 0.101325;

/// Default surface atmospheric pressure (bar) at sea level.
pub(crate) const DEFAULT_SURFACE_PRESSURE: f64 = 1.01325;

/// Fraction of N2 in air.
pub(crate) const AIR_FN2: f64 = 0.7902;

/// Fraction of O2 in air (for default gas).
pub(crate) const AIR_FO2: f64 = 0.2095;

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert depth in metres to absolute pressure in bar.
#[inline]
pub(crate) fn depth_to_pressure(depth_m: f64, surface_pressure: f64) -> f64 {
    surface_pressure + depth_m.max(0.0) * BAR_PER_METER
}

/// Convert absolute pressure in bar to depth in metres (clamped to >= 0).
#[inline]
pub(crate) fn pressure_to_depth(pressure_bar: f64, surface_pressure: f64) -> f64 {
    ((pressure_bar - surface_pressure) / BAR_PER_METER).max(0.0)
}

/// Compute inspired inert gas fractions (fN2, fHe) for a given gas and ambient state.
///
/// For CCR (ppo2 is Some): derives effective fractions from measured PPO2 and diluent ratio.
/// For OC (ppo2 is None): uses gas mix fractions directly.
#[inline]
pub(crate) fn inspired_fractions(
    fo2: f64,
    fhe: f64,
    ppo2: Option<f64>,
    ambient_p: f64,
) -> (f64, f64) {
    if let Some(ppo2) = ppo2 {
        let ppo2 = ppo2.clamp(0.0, ambient_p);
        let fo2_eff = ppo2 / ambient_p;
        let f_inert = (1.0 - fo2_eff).max(0.0);
        let dil_n2 = (1.0 - fo2 - fhe).max(0.0);
        let dil_inert = fhe + dil_n2;
        if dil_inert > 1e-10 {
            (f_inert * dil_n2 / dil_inert, f_inert * fhe / dil_inert)
        } else {
            (f_inert, 0.0)
        }
    } else {
        ((1.0 - fo2 - fhe).max(0.0), fhe)
    }
}

/// Single-compartment Schreiner equation step.
///
/// Returns the new tissue partial pressure after `dt_sec` seconds at
/// inspired partial pressure `p_inspired`, given half-time `half_time_min`.
#[inline]
pub(crate) fn schreiner_step(
    p_tissue: f64,
    p_inspired: f64,
    half_time_min: f64,
    dt_sec: f64,
) -> f64 {
    if dt_sec <= 0.0 {
        return p_tissue;
    }
    let k = (2.0_f64.ln()) / (half_time_min * 60.0);
    p_inspired + (p_tissue - p_inspired) * (-k * dt_sec).exp()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_depth_to_pressure() {
        let p = depth_to_pressure(10.0, DEFAULT_SURFACE_PRESSURE);
        assert!((p - (DEFAULT_SURFACE_PRESSURE + 10.0 * BAR_PER_METER)).abs() < 1e-10);
        // Negative depth clamped to 0
        assert_eq!(
            depth_to_pressure(-5.0, DEFAULT_SURFACE_PRESSURE),
            DEFAULT_SURFACE_PRESSURE
        );
    }

    #[test]
    fn test_pressure_to_depth() {
        let d = pressure_to_depth(
            DEFAULT_SURFACE_PRESSURE + 10.0 * BAR_PER_METER,
            DEFAULT_SURFACE_PRESSURE,
        );
        assert!((d - 10.0).abs() < 1e-10);
        // Below surface clamped to 0
        assert_eq!(pressure_to_depth(0.5, DEFAULT_SURFACE_PRESSURE), 0.0);
    }

    #[test]
    fn test_inspired_fractions_oc_air() {
        let (fn2, fhe) = inspired_fractions(AIR_FO2, 0.0, None, 4.0);
        assert!(
            (fn2 - AIR_FN2).abs() < 0.001,
            "OC air fN2={fn2}, expected ~{AIR_FN2}"
        );
        assert!(fhe.abs() < 1e-10, "OC air fHe={fhe}, expected 0");
    }

    #[test]
    fn test_inspired_fractions_oc_trimix() {
        // Trimix 21/35: fO2=0.21, fHe=0.35, fN2=0.44
        let (fn2, fhe) = inspired_fractions(0.21, 0.35, None, 4.0);
        assert!((fn2 - 0.44).abs() < 0.001, "fN2={fn2}, expected 0.44");
        assert!((fhe - 0.35).abs() < 0.001, "fHe={fhe}, expected 0.35");
    }

    #[test]
    fn test_inspired_fractions_ccr_basic() {
        // CCR on air diluent at 30m (4.04 bar), PPO2 = 1.3
        let ambient_p = DEFAULT_SURFACE_PRESSURE + 30.0 * BAR_PER_METER;
        let (fn2, fhe) = inspired_fractions(AIR_FO2, 0.0, Some(1.3), ambient_p);
        // fO2_eff = 1.3 / 4.04 ≈ 0.322
        // f_inert = 1.0 - 0.322 ≈ 0.678
        // dil_n2 = 1.0 - 0.2095 = 0.7905, dil_he = 0
        // fn2 = f_inert * dil_n2 / (dil_n2 + 0) = f_inert
        let fo2_eff = 1.3 / ambient_p;
        let expected_fn2 = 1.0 - fo2_eff;
        assert!(
            (fn2 - expected_fn2).abs() < 0.001,
            "CCR fN2={fn2}, expected {expected_fn2}"
        );
        assert!(fhe.abs() < 1e-10, "CCR on air diluent: fHe={fhe}");
        // Total inert should be less than OC air at same depth
        assert!(fn2 < AIR_FN2, "CCR should reduce inert loading vs OC");
    }

    #[test]
    fn test_inspired_fractions_ccr_trimix_diluent() {
        // CCR on trimix 21/35 diluent at 30m, PPO2 = 1.3
        let ambient_p = DEFAULT_SURFACE_PRESSURE + 30.0 * BAR_PER_METER;
        let (fn2, fhe) = inspired_fractions(0.21, 0.35, Some(1.3), ambient_p);
        let fo2_eff = 1.3 / ambient_p;
        let f_inert = 1.0 - fo2_eff;
        // dil_n2 = 1.0 - 0.21 - 0.35 = 0.44
        // dil_he = 0.35
        // dil_inert = 0.35 + 0.44 = 0.79
        let dil_n2 = 0.44;
        let dil_he = 0.35;
        let dil_inert = dil_n2 + dil_he;
        let expected_fn2 = f_inert * dil_n2 / dil_inert;
        let expected_fhe = f_inert * dil_he / dil_inert;
        assert!(
            (fn2 - expected_fn2).abs() < 0.001,
            "CCR trimix fN2={fn2}, expected {expected_fn2}"
        );
        assert!(
            (fhe - expected_fhe).abs() < 0.001,
            "CCR trimix fHe={fhe}, expected {expected_fhe}"
        );
        // Verify He:N2 ratio preserved from diluent
        let ratio_dil = dil_he / dil_n2;
        let ratio_result = fhe / fn2;
        assert!(
            (ratio_dil - ratio_result).abs() < 0.001,
            "He:N2 ratio not preserved: dil={ratio_dil}, result={ratio_result}"
        );
    }

    #[test]
    fn test_inspired_fractions_ccr_pure_o2_diluent() {
        // Edge case: pure O2 as "diluent" (dil_inert = 0)
        let (fn2, fhe) = inspired_fractions(1.0, 0.0, Some(1.0), 4.0);
        // fo2_eff = 1.0/4.0 = 0.25, f_inert = 0.75
        // dil_n2 = 0, dil_he = 0, dil_inert = 0 → fallback to (f_inert, 0.0)
        let expected = 1.0 - 1.0 / 4.0;
        assert!(
            (fn2 - expected).abs() < 0.001,
            "Pure O2 fallback: fn2={fn2}, expected {expected}"
        );
        assert!(fhe.abs() < 1e-10);
    }

    #[test]
    fn test_schreiner_step_zero_dt() {
        let result = schreiner_step(0.75, 3.0, 5.0, 0.0);
        assert_eq!(
            result, 0.75,
            "Zero dt should return unchanged tissue pressure"
        );
    }

    #[test]
    fn test_schreiner_step_exact() {
        // One half-time (5 min = 300 sec) → tissue should move halfway to inspired
        let p_tissue = 0.75;
        let p_inspired = 3.0;
        let result = schreiner_step(p_tissue, p_inspired, 5.0, 300.0);
        let expected = p_inspired + (p_tissue - p_inspired) * 0.5; // exactly one half-time
        assert!(
            (result - expected).abs() < 1e-10,
            "After one half-time: got {result}, expected {expected}"
        );
    }
}
