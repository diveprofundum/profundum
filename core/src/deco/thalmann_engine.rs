//! Thalmann EL-DCA decompression engine — stub.
//!
//! The Thalmann Exponential-Linear Decompression and Computing Algorithm
//! uses exponential-linear gas kinetics with Maximum Permissible Tissue
//! Tension (MPTT) tables. Phase 1b will implement:
//!
//! - E-L gas kinetics (exponential uptake during descent/bottom,
//!   linear elimination during ascent)
//! - MPTT tables for no-stop and decompression limits
//! - Surface Decompression Ratio (SDR) for sur-D-O2 procedures
//! - XVal parameter sets (air, N2O2, HeO2)
//!
//! See `thalmann-algorithm-reference.md` in project memory for details.

use super::types::{DecoSimError, DecoSimParams, DecoSimResult};

pub(crate) struct ThalmannEngine;

impl ThalmannEngine {
    pub(crate) fn simulate(&self, _params: &DecoSimParams) -> Result<DecoSimResult, DecoSimError> {
        Err(DecoSimError::UnsupportedModel {
            msg: "Thalmann EL-DCA is not yet implemented".to_string(),
        })
    }
}
