//! Types for the deco simulation engine.
//!
//! All types here are exposed via UniFFI to Swift/Kotlin.

// ============================================================================
// Input Types
// ============================================================================

/// Decompression model to use for the simulation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecoModel {
    /// Bühlmann ZHL-16C with gradient factors (Baker method).
    BuhlmannZhl16c,
    /// Thalmann EL-DCA with asymmetric E-L gas kinetics and MPTT ceilings.
    ThalmannElDca,
}

/// Parameters for a deco simulation run.
#[derive(Debug, Clone)]
pub struct DecoSimParams {
    /// Which deco model to use.
    pub model: DecoModel,
    /// Time-ordered depth/time/gas profile (same as existing SampleInput).
    pub samples: Vec<crate::metrics::SampleInput>,
    /// Gas mix definitions keyed by mix_index.
    pub gas_mixes: Vec<crate::buhlmann::GasMixInput>,
    /// Ambient surface pressure in bar (default 1.01325).
    pub surface_pressure_bar: Option<f64>,
    /// Ascent rate for deco planning in m/min (default 9.0).
    pub ascent_rate_m_min: Option<f64>,
    /// Depth of last stop in metres (default 3.0).
    pub last_stop_depth_m: Option<f64>,
    /// Stop spacing in metres (default 3.0).
    pub stop_interval_m: Option<f64>,
    /// Gradient factor low (0–100, Bühlmann only, default 100).
    pub gf_low: Option<u8>,
    /// Gradient factor high (0–100, Bühlmann only, default 100).
    pub gf_high: Option<u8>,
    /// If true, compute a deco schedule from the last sample to the surface.
    pub plan_ascent: bool,
}

// ============================================================================
// Output Types
// ============================================================================

/// Computed deco data for a single sample point.
#[derive(Debug, Clone)]
pub struct DecoSimPoint {
    /// Time offset from dive start (seconds).
    pub t_sec: i32,
    /// Depth in metres.
    pub depth_m: f32,
    /// GF-adjusted ceiling in metres (0 = no ceiling).
    pub ceiling_m: f32,
    /// GF99 — gradient factor at current ambient pressure (0–100+).
    pub gf99: f32,
    /// Surface gradient factor (0–100+).
    pub surface_gf: f32,
    /// Time-to-surface in seconds (0 if no deco obligation).
    pub tts_sec: i32,
    /// Index (0–15) of the leading (most loaded) compartment.
    pub leading_compartment: u8,
    /// No-decompression limit in seconds (0 if in deco).
    pub ndl_sec: i32,
}

/// A single deco stop in a planned ascent.
#[derive(Debug, Clone)]
pub struct DecoStop {
    /// Stop depth in metres.
    pub depth_m: f32,
    /// Duration at this stop in seconds.
    pub duration_sec: i32,
    /// Gas mix index used at this stop (-1 if default/unchanged).
    pub gas_mix_index: i32,
}

/// Complete result of a deco simulation.
#[derive(Debug, Clone)]
pub struct DecoSimResult {
    /// Per-sample computed deco data.
    pub points: Vec<DecoSimPoint>,
    /// Planned deco stops (empty if plan_ascent = false).
    pub deco_stops: Vec<DecoStop>,
    /// Total planned deco time in seconds (0 if no plan or no obligation).
    pub total_deco_time_sec: i32,
    /// Maximum ceiling observed across all samples.
    pub max_ceiling_m: f32,
    /// Maximum GF99 observed across all samples.
    pub max_gf99: f32,
    /// Maximum TTS observed across all samples.
    pub max_tts_sec: i32,
    /// The model that was used.
    pub model: DecoModel,
    /// True if the planner hit a safety limit (e.g., max stop time exceeded)
    /// and the deco schedule may be incomplete.
    pub truncated: bool,
}

/// Errors that can occur during deco simulation.
#[derive(Debug, Clone)]
pub enum DecoSimError {
    /// No samples provided.
    EmptySamples { msg: String },
    /// The requested model is not yet implemented.
    UnsupportedModel { msg: String },
    /// Invalid parameter (e.g., gf_low > gf_high).
    InvalidParam { msg: String },
}

impl std::fmt::Display for DecoSimError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DecoSimError::EmptySamples { msg } => write!(f, "EmptySamples: {msg}"),
            DecoSimError::UnsupportedModel { msg } => write!(f, "UnsupportedModel: {msg}"),
            DecoSimError::InvalidParam { msg } => write!(f, "InvalidParam: {msg}"),
        }
    }
}

impl std::error::Error for DecoSimError {}
