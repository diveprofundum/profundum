//! Thalmann EL-DCA parameter sets, unit conversions, and blood gas constants.
//!
//! All internal Thalmann computations use fsw (feet of seawater) units,
//! matching the NEDU reference implementation. Conversion to/from bar/metres
//! happens at the engine boundary.
//!
//! Reference: NEDU TR 18-05 (Doolette, Murphy, Gerth 2018).

// ============================================================================
// Unit conversion constants
// ============================================================================

/// Feet of seawater per atmosphere (USN convention).
pub(crate) const FSW_PER_ATM: f64 = 33.0;

/// Metres per foot (exact).
const M_PER_FT: f64 = 0.3048;

// ============================================================================
// Unit conversion helpers
// ============================================================================

/// Convert pressure in bar to fsw.
#[inline]
pub(crate) fn bar_to_fsw(p_bar: f64) -> f64 {
    p_bar / 1.01325 * FSW_PER_ATM
}

/// Convert pressure in fsw to bar.
#[inline]
#[cfg(test)]
pub(crate) fn fsw_to_bar(p_fsw: f64) -> f64 {
    p_fsw / FSW_PER_ATM * 1.01325
}

/// Convert depth in metres to fsw.
#[inline]
pub(crate) fn meters_to_fsw(m: f64) -> f64 {
    m / M_PER_FT
}

/// Convert depth in fsw to metres.
#[inline]
pub(crate) fn fsw_to_meters(fsw: f64) -> f64 {
    fsw * M_PER_FT
}

// ============================================================================
// Blood gas constants (fixed across all parameter sets, from TR 18-05)
// ============================================================================

/// Arterial CO2 partial pressure (fsw). Used in place of Bühlmann's water
/// vapour correction for computing inspired gas partial pressures.
pub(crate) const PACO2_FSW: f64 = 1.5;

/// Venous CO2 partial pressure (fsw).
const PVCO2_FSW: f64 = 2.3;

/// Venous O2 partial pressure (fsw).
const PVO2_FSW: f64 = 2.0;

/// Water vapour pressure (fsw) — zero in most Thalmann parameter sets.
const PH2O_FSW: f64 = 0.0;

/// Fixed venous gas pressure = PVO2 + PVCO2 + PH2O.
/// This is the threshold for supersaturation sensing.
pub(crate) const P_FVG_FSW: f64 = PVO2_FSW + PVCO2_FSW + PH2O_FSW; // 4.3

// ============================================================================
// Parameter set structure
// ============================================================================

/// A Thalmann decompression parameter set.
///
/// Each set defines compartment half-times, saturation/desaturation ratios,
/// and MPTT (Maximum Permissible Tissue Tension) linear coefficients.
pub(crate) struct ThalmannParamSet {
    /// Number of tissue compartments.
    pub num_compartments: usize,
    /// On-gassing half-times in minutes, per compartment.
    pub half_times_min: &'static [f64],
    /// Saturation/Desaturation Ratio per compartment.
    /// SDR > 1 means faster washout; SDR < 1 means slower washout.
    /// Must be > 0 (SDR=0 causes division by zero).
    pub sdr: &'static [f64],
    /// Surfacing M-value (M0) in fsw, per compartment.
    pub m0_fsw: &'static [f64],
    /// MPTT slope per compartment. M_i(D) = M0[i] + beta1[i] * D.
    /// Must be > 0 (beta1=0 causes division by zero in ceiling computation).
    pub beta1: &'static [f64],
    /// Threshold inert gas overpressure for linear washout transition (fsw).
    /// 0.0 means crossover whenever tissue is supersaturated past venous gas deficit.
    pub pbovp_fsw: f64,
}

impl ThalmannParamSet {
    /// Validate that all parameter arrays are consistent and values are in
    /// valid ranges. Returns an error message if invalid.
    pub(crate) fn validate(&self) -> Result<(), String> {
        let n = self.num_compartments;
        if n == 0 {
            return Err("num_compartments must be > 0".to_string());
        }
        if self.half_times_min.len() != n
            || self.sdr.len() != n
            || self.m0_fsw.len() != n
            || self.beta1.len() != n
        {
            return Err(format!(
                "Parameter array lengths must all equal num_compartments ({n})"
            ));
        }
        for i in 0..n {
            if self.half_times_min[i] <= 0.0 {
                return Err(format!("half_times_min[{i}] must be > 0"));
            }
            if self.sdr[i] <= 0.0 {
                return Err(format!("sdr[{i}] must be > 0"));
            }
            if self.beta1[i] <= 0.0 {
                return Err(format!("beta1[{i}] must be > 0"));
            }
        }
        Ok(())
    }
}

// ============================================================================
// XVal-He-9_023 parameter set (TR 18-05, Table 10)
// ============================================================================

/// XVal-He-9_023: 5-compartment He-O2 parameter set at 2.3% target P_DCS.
///
/// This is the primary parameter set for He-O2 diving to 300 fsw with
/// 1.3 atm PO2. Includes a repetitive-group reference compartment (#4).
pub(crate) static XVAL_HE_9_023: ThalmannParamSet = ThalmannParamSet {
    num_compartments: 5,
    half_times_min: &[10.0, 20.0, 20.0, 120.0, 210.0],
    sdr: &[1.0, 2.0, 0.67, 1.0, 1.0],
    m0_fsw: &[85.0, 64.0, 83.0, 41.731, 34.165],
    beta1: &[1.0, 1.0, 1.0, 2.0, 1.0],
    pbovp_fsw: 0.0,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bar_to_fsw_roundtrip() {
        let original = 4.05; // ~30m depth
        let fsw = bar_to_fsw(original);
        let back = fsw_to_bar(fsw);
        assert!(
            (back - original).abs() < 1e-10,
            "bar→fsw→bar roundtrip: {original} → {fsw} → {back}"
        );
    }

    #[test]
    fn test_meters_to_fsw_roundtrip() {
        let original = 30.0;
        let fsw = meters_to_fsw(original);
        let back = fsw_to_meters(fsw);
        assert!(
            (back - original).abs() < 1e-10,
            "m→fsw→m roundtrip: {original} → {fsw} → {back}"
        );
    }

    #[test]
    fn test_surface_pressure_conversion() {
        // 1 atm = 1.01325 bar = 33 fsw
        let surface_fsw = bar_to_fsw(1.01325);
        assert!(
            (surface_fsw - 33.0).abs() < 1e-10,
            "1 atm should be 33 fsw, got {surface_fsw}"
        );
    }

    #[test]
    fn test_p_fvg_value() {
        // P_FVG = PVO2 + PVCO2 + PH2O = 2.0 + 2.3 + 0.0 = 4.3
        assert!(
            (P_FVG_FSW - 4.3).abs() < 1e-10,
            "P_FVG should be 4.3 fsw, got {P_FVG_FSW}"
        );
    }

    #[test]
    fn test_xval_he_9_023_params() {
        assert_eq!(XVAL_HE_9_023.num_compartments, 5);
        assert_eq!(XVAL_HE_9_023.half_times_min.len(), 5);
        assert_eq!(XVAL_HE_9_023.sdr.len(), 5);
        assert_eq!(XVAL_HE_9_023.m0_fsw.len(), 5);
        assert_eq!(XVAL_HE_9_023.beta1.len(), 5);
        assert!((XVAL_HE_9_023.pbovp_fsw).abs() < 1e-10);
    }

    #[test]
    fn test_known_depth_conversion() {
        // 10m = 32.808 ft ≈ 32.808 fsw
        let fsw = meters_to_fsw(10.0);
        let expected = 10.0 / 0.3048;
        assert!(
            (fsw - expected).abs() < 1e-6,
            "10m should be {expected} fsw, got {fsw}"
        );
    }
}
