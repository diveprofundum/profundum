//! Metrics computation for dive data.
//!
//! This module provides pure functions to compute statistics from dive samples.
//! All inputs are plain data structures - no database or storage dependencies.

/// Classification of dive depth ranges.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DepthClass {
    /// 0-18m (0-60ft) - recreational limit
    Recreational,
    /// 18-40m (60-130ft) - deep recreational
    Deep,
    /// 40-60m (130-200ft) - extended range / technical
    Extended,
    /// 60m+ (200ft+) - extreme technical
    Extreme,
}

impl DepthClass {
    pub fn from_depth_m(depth: f32) -> Self {
        if depth <= 18.0 {
            DepthClass::Recreational
        } else if depth <= 40.0 {
            DepthClass::Deep
        } else if depth <= 60.0 {
            DepthClass::Extended
        } else {
            DepthClass::Extreme
        }
    }

    pub fn label(&self) -> &'static str {
        match self {
            DepthClass::Recreational => "Recreational",
            DepthClass::Deep => "Deep",
            DepthClass::Extended => "Extended Range",
            DepthClass::Extreme => "Extreme",
        }
    }
}

/// Input data for a dive (minimal required fields for stats computation).
#[derive(Debug, Clone)]
pub struct DiveInput {
    /// Start time as Unix timestamp
    pub start_time_unix: i64,
    /// End time as Unix timestamp
    pub end_time_unix: i64,
    /// Bottom time in seconds (from dive computer / legacy fallback)
    pub bottom_time_sec: i32,
    /// Whether this is a CCR dive (affects deco_start_t detection)
    pub is_ccr: bool,
    /// Manual override for bottom_end_t (user correction, in seconds from dive start)
    pub bottom_end_t_override_sec: Option<i32>,
    /// Manual override for deco_start_t (user correction, in seconds from dive start)
    pub deco_start_t_override_sec: Option<i32>,
}

/// Input data for a sample point.
#[derive(Debug, Clone)]
pub struct SampleInput {
    /// Time offset from dive start in seconds
    pub t_sec: i32,
    /// Depth in meters
    pub depth_m: f32,
    /// Temperature in Celsius
    pub temp_c: f32,
    /// Setpoint PPO2 (for CCR, optional)
    pub setpoint_ppo2: Option<f32>,
    /// Deco ceiling in meters (optional)
    pub ceiling_m: Option<f32>,
    /// GF99 value (optional)
    pub gf99: Option<f32>,
    /// Gas mix index (identifies which gas is being breathed)
    pub gasmix_index: Option<i32>,
    /// Actual measured PPO2 (for CCR); None = OC, use gas fractions
    pub ppo2: Option<f32>,
    /// Time to surface in seconds (from dive computer)
    pub tts_sec: Option<i32>,
    /// No-decompression limit in seconds (from dive computer)
    pub ndl_sec: Option<i32>,
    /// Required deco stop depth in meters (from dive computer)
    pub deco_stop_depth_m: Option<f32>,
    /// Projected TTS in minutes if diver stays 5 more minutes at current depth
    pub at_plus_five_tts_min: Option<i32>,
}

/// Computed statistics for a dive.
#[derive(Debug, Clone)]
pub struct DiveStats {
    /// Total dive time in seconds
    pub total_time_sec: i32,
    /// Bottom time in seconds (deco dives: descent + time at working depth; non-deco: 0)
    pub bottom_time_sec: i32,
    /// Deco time in seconds (all time from deco_start_t to end of dive)
    pub deco_time_sec: i32,
    /// Total time with deco obligation in seconds (all time with ceiling > 0, including at depth)
    pub deco_obligation_sec: i32,
    /// Peak time-to-surface in seconds during the dive
    pub max_tts_sec: i32,
    /// Maximum depth reached
    pub max_depth_m: f32,
    /// Average depth across all samples
    pub avg_depth_m: f32,
    /// Time-weighted average depth
    pub weighted_avg_depth_m: f32,
    /// Minimum temperature recorded
    pub min_temp_c: f32,
    /// Maximum temperature recorded
    pub max_temp_c: f32,
    /// Average temperature
    pub avg_temp_c: f32,
    /// Depth classification
    pub depth_class: DepthClass,
    /// Number of gas/setpoint switches detected
    pub gas_switch_count: u32,
    /// Maximum ceiling encountered (in meters)
    pub max_ceiling_m: f32,
    /// Maximum GF99 value
    pub max_gf99: f32,
    /// Descent rate (m/min) - first phase
    pub descent_rate_m_min: f32,
    /// Ascent rate (m/min) - final phase
    pub ascent_rate_m_min: f32,
    /// Time (seconds from dive start) when bottom phase ends (diver leaves working depth)
    pub bottom_end_t: i32,
    /// Time (seconds from dive start) when deco phase begins (first stop / gas switch)
    pub deco_start_t: i32,
    /// Transit time from working depth to first deco stop (= deco_start_t - bottom_end_t)
    pub ascent_time_sec: i32,
}

// ── Bottom-end detection constants ──
const ASCENT_WINDOW_SEC: i32 = 120;
const ASCENT_THRESHOLD_M_MIN: f32 = 1.5;
const DELTA5_THRESHOLD: i32 = 5;
const FALLBACK_PERCENT: f32 = 0.80;

/// Compute bottom_end_t using multi-signal detection.
///
/// Identifies the end of working depth by finding the first sustained ascent
/// after which the diver never returns to significant depth (≥50% of max).
///
/// Signals used:
/// 1. Rolling 120s ascent rate > 1.5 m/min (primary trigger)
/// 2. Return-to-depth check: if diver returns to ≥50% max depth, it's a level
///    change within the working phase, not the final departure
/// 3. Δ+5 ≥ 5 check (on-gassing deferral for shallow working depths)
/// 4. 80% of max depth fallback
fn compute_bottom_end_t(samples: &[SampleInput], max_depth_m: f32) -> i32 {
    if samples.len() < 2 || max_depth_m <= 0.0 {
        return 0;
    }

    // Step 1: Precompute rolling 120s ascent rate per sample (m/min, positive = ascending)
    let mut ascent_rates: Vec<f32> = vec![0.0; samples.len()];
    for i in 0..samples.len() {
        // Find the sample approximately ASCENT_WINDOW_SEC earlier
        let target_t = samples[i].t_sec - ASCENT_WINDOW_SEC;
        // Find closest sample at or before target_t
        let mut j = i;
        while j > 0 && samples[j].t_sec > target_t {
            j -= 1;
        }
        if j < i {
            let dt_sec = samples[i].t_sec - samples[j].t_sec;
            if dt_sec > 0 {
                let depth_change = samples[j].depth_m - samples[i].depth_m; // positive = ascending
                ascent_rates[i] = depth_change / (dt_sec as f32 / 60.0);
            }
        }
    }

    // Find the first time the diver reaches 50% of max depth (skip descent phase)
    let half_max = max_depth_m * 0.5;
    let first_deep_t = samples
        .iter()
        .find(|s| s.depth_m >= half_max)
        .map_or(0, |s| s.t_sec);

    // Precompute max depth from each sample to end of dive.
    // Used for "return to depth" check: if the diver returns to ≥50% max depth
    // after a candidate, they're still in the working phase.
    let mut max_depth_after: Vec<f32> = vec![0.0; samples.len()];
    for i in (0..samples.len().saturating_sub(1)).rev() {
        max_depth_after[i] = samples[i + 1].depth_m.max(max_depth_after[i + 1]);
    }

    // Minimum depth for candidates: must be deeper than 25% of max depth.
    // Prevents false positives at shallow deco stops (3-6m) where the
    // diver ascends straight to the surface without leveling off.
    let min_candidate_depth = max_depth_m * 0.25;

    // Step 2: Scan for ascent candidates
    for i in 0..samples.len() {
        if ascent_rates[i] < ASCENT_THRESHOLD_M_MIN {
            continue;
        }

        // Time guard: skip candidates before diver reaches working depth
        if samples[i].t_sec < first_deep_t {
            continue;
        }

        // Depth guard: skip candidates at very shallow depths (deco stops, surface)
        if samples[i].depth_m < min_candidate_depth {
            continue;
        }

        // Return-to-depth check: if the diver returns to ≥50% of max depth
        // after this point, this is a level change within the working phase,
        // not the final departure. Works with any sample density.
        if max_depth_after[i] >= half_max {
            continue;
        }

        // Δ+5 check: if available and majority have Δ+5 ≥ threshold, diver still on-gassing
        let check_start = i.saturating_sub(5);
        let check_end = (i + 5).min(samples.len());
        let delta5_samples: Vec<_> = samples[check_start..check_end]
            .iter()
            .filter_map(|s| s.at_plus_five_tts_min)
            .collect();
        if !delta5_samples.is_empty() {
            let positive_count = delta5_samples
                .iter()
                .filter(|&&v| v >= DELTA5_THRESHOLD)
                .count();
            if positive_count * 2 > delta5_samples.len() {
                continue; // Still on-gassing, defer trigger
            }
        }

        // Confirmed! Walk back to find depth peak in preceding 120s window
        let window_start_t = samples[i].t_sec - ASCENT_WINDOW_SEC;
        let mut peak_t = samples[i].t_sec;
        let mut peak_depth = samples[i].depth_m;
        for k in (0..i).rev() {
            if samples[k].t_sec < window_start_t {
                break;
            }
            if samples[k].depth_m > peak_depth {
                peak_depth = samples[k].depth_m;
                peak_t = samples[k].t_sec;
            }
        }
        return peak_t;
    }

    // Fallback: last sample with depth ≥ 80% of max depth
    let threshold = max_depth_m * FALLBACK_PERCENT;
    samples
        .iter()
        .rposition(|s| s.depth_m >= threshold)
        .map_or(0, |idx| samples[idx].t_sec)
}

/// Compute deco_start_t: the time when the deco phase begins.
///
/// For OC dives: first gas switch after bottom_end_t marks the start of deco.
/// For CCR dives: first sample after bottom_end_t where depth approaches ceiling
///   and diver levels off (arriving at first deco stop).
/// Fallback: first sample after bottom_end_t with ceiling > 0.
fn compute_deco_start_t(samples: &[SampleInput], bottom_end_t: i32, is_ccr: bool) -> i32 {
    if bottom_end_t == 0 {
        return 0;
    }

    if !is_ccr {
        // OC: first gas switch after bottom_end_t
        let mut prev_gasmix: Option<i32> = None;
        // Establish the gas mix at bottom_end_t
        for s in samples.iter() {
            if s.t_sec > bottom_end_t {
                break;
            }
            if let Some(idx) = s.gasmix_index {
                prev_gasmix = Some(idx);
            }
        }
        // Find first change after bottom_end_t
        if let Some(prev) = prev_gasmix {
            for s in samples.iter() {
                if s.t_sec <= bottom_end_t {
                    continue;
                }
                if let Some(idx) = s.gasmix_index {
                    if idx != prev {
                        return s.t_sec;
                    }
                }
            }
        }
    } else {
        // CCR: first sample after bottom_end_t where depth approaches ceiling
        // and diver holds position (depth stays within ±2m band for 20s).
        // This is robust to sensor noise at 2-second sample intervals where
        // even 5cm depth oscillations produce high instantaneous rates.
        // Works for deep ceilings too — the signal is proximity to ceiling,
        // not absolute depth.
        for (i, s) in samples.iter().enumerate() {
            if s.t_sec <= bottom_end_t {
                continue;
            }
            if let Some(ceiling) = s.ceiling_m {
                if ceiling > 0.0 && s.depth_m <= ceiling + 3.0 {
                    // Depth-band hold check: diver stays within ±2m for 20s
                    let anchor = s.depth_m;
                    let mut hold_t = 0i32;
                    let mut found = false;
                    for k in i..samples.len() {
                        if (samples[k].depth_m - anchor).abs() > 2.0 {
                            break;
                        }
                        let dt = if k + 1 < samples.len() {
                            (samples[k + 1].t_sec - samples[k].t_sec).max(1)
                        } else {
                            1
                        };
                        hold_t += dt;
                        if hold_t >= 20 {
                            found = true;
                            break;
                        }
                    }
                    if found {
                        return s.t_sec;
                    }
                }
            }
        }
    }

    // Fallback: first sample after bottom_end_t with ceiling > 0
    for s in samples.iter() {
        if s.t_sec <= bottom_end_t {
            continue;
        }
        if let Some(ceiling) = s.ceiling_m {
            if ceiling > 0.0 {
                return s.t_sec;
            }
        }
    }

    // No deco detected after bottom_end_t — no ascent/deco phase
    0
}

impl DiveStats {
    /// Compute statistics from dive input and samples.
    pub fn compute(dive: &DiveInput, samples: &[SampleInput]) -> Self {
        if samples.is_empty() {
            return Self::from_dive_only(dive);
        }

        let total_time_sec = dive.end_time_unix - dive.start_time_unix;

        // ── Pass 1: pre-scan for max depth, deco detection, bottom_end_t ──
        let mut max_depth_m: f32 = 0.0;
        let mut has_deco = false;

        for sample in samples {
            if sample.depth_m > max_depth_m {
                max_depth_m = sample.depth_m;
            }
            if let Some(ceiling) = sample.ceiling_m {
                if ceiling > 0.0 {
                    has_deco = true;
                }
            }
        }

        // bottom_end_t: multi-signal detection of when diver leaves working depth
        let bottom_end_t: i32 = if has_deco && max_depth_m > 0.0 {
            dive.bottom_end_t_override_sec
                .unwrap_or_else(|| compute_bottom_end_t(samples, max_depth_m))
        } else {
            0
        };

        // deco_start_t: when deco phase begins (gas switch for OC, first stop for CCR)
        let deco_start_t: i32 = if has_deco && bottom_end_t > 0 {
            dive.deco_start_t_override_sec
                .unwrap_or_else(|| compute_deco_start_t(samples, bottom_end_t, dive.is_ccr))
        } else {
            0
        };

        // ── Pass 2: main loop ──
        let mut depth_sum: f64 = 0.0;
        let mut weighted_depth_sum: f64 = 0.0;
        let mut weight_sum: f64 = 0.0;
        let mut min_temp_c = f32::MAX;
        let mut max_temp_c = f32::MIN;
        let mut temp_sum: f64 = 0.0;

        // Deco tracking
        let mut deco_obligation_sec: i32 = 0;
        let mut max_ceiling_m: f32 = 0.0;
        let mut max_gf99: f32 = 0.0;
        let mut max_tts_sec: i32 = 0;

        // Gas switch detection (by gasmix_index changes)
        let mut gas_switch_count: u32 = 0;
        let mut prev_gasmix_index: Option<i32> = None;

        for (i, sample) in samples.iter().enumerate() {
            // Depth stats
            depth_sum += sample.depth_m as f64;

            // Weighted average: weight by time interval
            let dt = if i + 1 < samples.len() {
                (samples[i + 1].t_sec - sample.t_sec) as f64
            } else if i > 0 {
                (sample.t_sec - samples[i - 1].t_sec) as f64
            } else {
                1.0
            };
            weighted_depth_sum += sample.depth_m as f64 * dt;
            weight_sum += dt;

            // Temperature stats
            if sample.temp_c < min_temp_c {
                min_temp_c = sample.temp_c;
            }
            if sample.temp_c > max_temp_c {
                max_temp_c = sample.temp_c;
            }
            temp_sum += sample.temp_c as f64;

            // Deco obligation: total time with ceiling > 0
            if let Some(ceiling) = sample.ceiling_m {
                if ceiling > 0.0 {
                    let deco_dt = if i + 1 < samples.len() {
                        samples[i + 1].t_sec - sample.t_sec
                    } else if i > 0 {
                        sample.t_sec - samples[i - 1].t_sec
                    } else {
                        1
                    };
                    deco_obligation_sec += deco_dt;
                }
                if ceiling > max_ceiling_m {
                    max_ceiling_m = ceiling;
                }
            }

            // Max GF99
            if let Some(gf99) = sample.gf99 {
                if gf99 > max_gf99 {
                    max_gf99 = gf99;
                }
            }

            // Max TTS
            if let Some(tts) = sample.tts_sec {
                if tts > max_tts_sec {
                    max_tts_sec = tts;
                }
            }

            // Gas switch detection: count changes in gasmix_index
            if let Some(idx) = sample.gasmix_index {
                if let Some(prev) = prev_gasmix_index {
                    if idx != prev {
                        gas_switch_count += 1;
                    }
                }
                prev_gasmix_index = Some(idx);
            }
        }

        // Bottom time: only meaningful for deco dives.
        let bottom_time_sec: i32 = if has_deco { bottom_end_t } else { 0 };

        let avg_depth_m = if !samples.is_empty() {
            (depth_sum / samples.len() as f64) as f32
        } else {
            0.0
        };

        let weighted_avg_depth_m = if weight_sum > 0.0 {
            (weighted_depth_sum / weight_sum) as f32
        } else {
            avg_depth_m
        };

        let avg_temp_c = if !samples.is_empty() {
            (temp_sum / samples.len() as f64) as f32
        } else {
            0.0
        };

        // Descent and ascent rates
        let (descent_rate_m_min, ascent_rate_m_min) = Self::compute_rates(samples);

        // Handle edge cases for temperature
        if min_temp_c == f32::MAX {
            min_temp_c = 0.0;
        }
        if max_temp_c == f32::MIN {
            max_temp_c = 0.0;
        }

        // deco_time_sec: all time from deco_start_t to end of dive
        let deco_time_sec: i32 = if deco_start_t > 0 {
            total_time_sec as i32 - deco_start_t
        } else {
            0
        };

        let ascent_time_sec = if deco_start_t > bottom_end_t {
            deco_start_t - bottom_end_t
        } else {
            0
        };

        DiveStats {
            total_time_sec: total_time_sec as i32,
            bottom_time_sec,
            deco_time_sec,
            deco_obligation_sec,
            max_tts_sec,
            max_depth_m,
            avg_depth_m,
            weighted_avg_depth_m,
            min_temp_c,
            max_temp_c,
            avg_temp_c,
            depth_class: DepthClass::from_depth_m(max_depth_m),
            gas_switch_count,
            max_ceiling_m,
            max_gf99,
            descent_rate_m_min,
            ascent_rate_m_min,
            bottom_end_t,
            deco_start_t,
            ascent_time_sec,
        }
    }

    fn from_dive_only(dive: &DiveInput) -> Self {
        DiveStats {
            total_time_sec: (dive.end_time_unix - dive.start_time_unix) as i32,
            bottom_time_sec: dive.bottom_time_sec,
            deco_time_sec: 0,
            deco_obligation_sec: 0,
            max_tts_sec: 0,
            max_depth_m: 0.0,
            avg_depth_m: 0.0,
            weighted_avg_depth_m: 0.0,
            min_temp_c: 0.0,
            max_temp_c: 0.0,
            avg_temp_c: 0.0,
            depth_class: DepthClass::Recreational,
            gas_switch_count: 0,
            max_ceiling_m: 0.0,
            max_gf99: 0.0,
            descent_rate_m_min: 0.0,
            ascent_rate_m_min: 0.0,
            bottom_end_t: 0,
            deco_start_t: 0,
            ascent_time_sec: 0,
        }
    }

    /// Computes average descent and ascent rates in m/min.
    ///
    /// Descent is measured from surface to first arrival at max depth; ascent from
    /// last departure from max depth to surface. Bottom time at max depth is
    /// excluded from both calculations.
    fn compute_rates(samples: &[SampleInput]) -> (f32, f32) {
        if samples.len() < 2 {
            return (0.0, 0.0);
        }

        let max_depth = samples
            .iter()
            .map(|s| s.depth_m)
            .fold(f32::NEG_INFINITY, f32::max);

        let first_max_idx = samples
            .iter()
            .position(|s| s.depth_m == max_depth)
            .unwrap_or(0);

        let last_max_idx = samples.len()
            - 1
            - samples
                .iter()
                .rev()
                .position(|s| s.depth_m == max_depth)
                .unwrap_or(0);

        // Descent: surface → first arrival at max depth
        let descent_rate = if first_max_idx > 0 {
            let dt_min = (samples[first_max_idx].t_sec - samples[0].t_sec) as f32 / 60.0;
            if dt_min > 0.0 {
                samples[first_max_idx].depth_m / dt_min
            } else {
                0.0
            }
        } else {
            0.0
        };

        // Ascent: last departure from max depth → surface
        let ascent_rate = if last_max_idx < samples.len() - 1 {
            let last = samples.last().unwrap();
            let dt_min = (last.t_sec - samples[last_max_idx].t_sec) as f32 / 60.0;
            if dt_min > 0.0 {
                (samples[last_max_idx].depth_m - last.depth_m) / dt_min
            } else {
                0.0
            }
        } else {
            0.0
        };

        (descent_rate, ascent_rate)
    }
}

/// Computed statistics for a segment of a dive.
#[derive(Debug, Clone)]
pub struct SegmentStats {
    /// Duration of segment in seconds
    pub duration_sec: i32,
    /// Maximum depth in segment
    pub max_depth_m: f32,
    /// Average depth in segment
    pub avg_depth_m: f32,
    /// Minimum temperature in segment
    pub min_temp_c: f32,
    /// Maximum temperature in segment
    pub max_temp_c: f32,
    /// Deco time within segment (ascent-phase only, using dive-level bottom_end_t)
    pub deco_time_sec: i32,
    /// Total time with deco obligation in segment (all time with ceiling > 0)
    pub deco_obligation_sec: i32,
    /// Peak TTS in segment
    pub max_tts_sec: i32,
    /// Number of samples in segment
    pub sample_count: u64,
}

impl SegmentStats {
    /// Compute statistics for a segment from samples within its time range.
    ///
    /// `dive_bottom_end_t` is the dive-level bottom-end time.
    /// `dive_deco_start_t` is the dive-level deco-start time.
    /// `deco_time_sec` = overlap of [deco_start_t, end_t_sec] with segment range.
    /// `deco_obligation_sec` = total time with ceiling > 0 within segment.
    pub fn compute(
        start_t_sec: i32,
        end_t_sec: i32,
        all_samples: &[SampleInput],
        _dive_bottom_end_t: i32,
        dive_deco_start_t: i32,
    ) -> Self {
        let samples: Vec<_> = all_samples
            .iter()
            .filter(|s| s.t_sec >= start_t_sec && s.t_sec <= end_t_sec)
            .collect();

        if samples.is_empty() {
            return Self {
                duration_sec: end_t_sec - start_t_sec,
                max_depth_m: 0.0,
                avg_depth_m: 0.0,
                min_temp_c: 0.0,
                max_temp_c: 0.0,
                deco_time_sec: 0,
                deco_obligation_sec: 0,
                max_tts_sec: 0,
                sample_count: 0,
            };
        }

        let mut max_depth_m: f32 = 0.0;
        let mut depth_sum: f64 = 0.0;
        let mut min_temp_c = f32::MAX;
        let mut max_temp_c = f32::MIN;
        let mut deco_obligation_sec: i32 = 0;
        let mut max_tts_sec: i32 = 0;

        for (i, sample) in samples.iter().enumerate() {
            if sample.depth_m > max_depth_m {
                max_depth_m = sample.depth_m;
            }
            depth_sum += sample.depth_m as f64;

            if sample.temp_c < min_temp_c {
                min_temp_c = sample.temp_c;
            }
            if sample.temp_c > max_temp_c {
                max_temp_c = sample.temp_c;
            }

            if let Some(ceiling) = sample.ceiling_m {
                if ceiling > 0.0 {
                    let dt = if i + 1 < samples.len() {
                        samples[i + 1].t_sec - sample.t_sec
                    } else if i > 0 {
                        sample.t_sec - samples[i - 1].t_sec
                    } else {
                        1
                    };
                    deco_obligation_sec += dt;
                }
            }

            if let Some(tts) = sample.tts_sec {
                if tts > max_tts_sec {
                    max_tts_sec = tts;
                }
            }
        }

        if min_temp_c == f32::MAX {
            min_temp_c = 0.0;
        }
        if max_temp_c == f32::MIN {
            max_temp_c = 0.0;
        }

        // deco_time_sec: overlap of [deco_start_t, ∞) with segment [start_t, end_t]
        let deco_time_sec: i32 = if dive_deco_start_t > 0 && end_t_sec > dive_deco_start_t {
            end_t_sec - dive_deco_start_t.max(start_t_sec)
        } else {
            0
        };

        SegmentStats {
            duration_sec: end_t_sec - start_t_sec,
            max_depth_m,
            avg_depth_m: (depth_sum / samples.len() as f64) as f32,
            min_temp_c,
            max_temp_c,
            deco_time_sec,
            deco_obligation_sec,
            max_tts_sec,
            sample_count: samples.len() as u64,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_dive() -> DiveInput {
        DiveInput {
            start_time_unix: 1700000000,
            end_time_unix: 1700003600,
            bottom_time_sec: 3000,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        }
    }

    fn create_test_samples() -> Vec<SampleInput> {
        vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
                temp_c: 22.0,
                setpoint_ppo2: Some(1.0),
                ceiling_m: Some(0.0),
                gf99: Some(0.0),
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 60,
                depth_m: 10.0,
                temp_c: 20.0,
                setpoint_ppo2: Some(1.0),
                ceiling_m: Some(0.0),
                gf99: Some(20.0),
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 120,
                depth_m: 20.0,
                temp_c: 18.0,
                setpoint_ppo2: Some(1.3),
                ceiling_m: Some(0.0),
                gf99: Some(40.0),
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 300,
                depth_m: 30.0,
                temp_c: 16.0,
                setpoint_ppo2: Some(1.3),
                ceiling_m: Some(3.0),
                gf99: Some(60.0),
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 600,
                depth_m: 30.0,
                temp_c: 16.0,
                setpoint_ppo2: Some(1.3),
                ceiling_m: Some(6.0),
                gf99: Some(80.0),
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 900,
                depth_m: 20.0,
                temp_c: 17.0,
                setpoint_ppo2: Some(1.0),
                ceiling_m: Some(3.0),
                gf99: Some(70.0),
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 1200,
                depth_m: 5.0,
                temp_c: 19.0,
                setpoint_ppo2: Some(1.0),
                ceiling_m: Some(0.0),
                gf99: Some(50.0),
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 1500,
                depth_m: 0.0,
                temp_c: 21.0,
                setpoint_ppo2: Some(1.0),
                ceiling_m: Some(0.0),
                gf99: Some(30.0),
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ]
    }

    #[test]
    fn test_depth_class() {
        assert_eq!(DepthClass::from_depth_m(10.0), DepthClass::Recreational);
        assert_eq!(DepthClass::from_depth_m(18.0), DepthClass::Recreational);
        assert_eq!(DepthClass::from_depth_m(25.0), DepthClass::Deep);
        assert_eq!(DepthClass::from_depth_m(40.0), DepthClass::Deep);
        assert_eq!(DepthClass::from_depth_m(50.0), DepthClass::Extended);
        assert_eq!(DepthClass::from_depth_m(70.0), DepthClass::Extreme);
    }

    #[test]
    fn test_dive_stats_compute() {
        let dive = create_test_dive();
        let samples = create_test_samples();

        let stats = DiveStats::compute(&dive, &samples);

        assert_eq!(stats.max_depth_m, 30.0);
        assert!(stats.avg_depth_m > 0.0);
        assert!(stats.weighted_avg_depth_m > 0.0);
        assert_eq!(stats.min_temp_c, 16.0);
        assert_eq!(stats.max_temp_c, 22.0);
        assert!(stats.deco_obligation_sec > 0);
        assert_eq!(stats.max_ceiling_m, 6.0);
        assert_eq!(stats.max_gf99, 80.0);
        assert_eq!(stats.gas_switch_count, 0); // all gasmix_index are None
        assert_eq!(stats.depth_class, DepthClass::Deep);
        // Descent: 30m over 5 min (first max at t=300) = 6.0 m/min
        assert!((stats.descent_rate_m_min - 6.0).abs() < 0.01);
        // Ascent: 30m over 15 min (last max at t=600, end at t=1500) = 2.0 m/min
        assert!((stats.ascent_rate_m_min - 2.0).abs() < 0.01);
        // New fields: bottom_end_t and deco_start_t are set for deco dives
        assert!(stats.bottom_end_t > 0);
    }

    #[test]
    fn test_dive_stats_empty_samples() {
        let dive = create_test_dive();
        let stats = DiveStats::compute(&dive, &[]);

        assert_eq!(stats.total_time_sec, 3600);
        assert_eq!(stats.bottom_time_sec, dive.bottom_time_sec);
    }

    #[test]
    fn test_segment_stats() {
        let samples = create_test_samples();

        let stats = SegmentStats::compute(300, 600, &samples, 0, 300);

        assert_eq!(stats.duration_sec, 300);
        assert_eq!(stats.max_depth_m, 30.0);
        assert_eq!(stats.min_temp_c, 16.0);
        assert!(stats.deco_time_sec > 0);
        assert_eq!(stats.sample_count, 2);
    }

    #[test]
    fn test_segment_stats_empty() {
        let stats = SegmentStats::compute(5000, 6000, &[], 0, 0);

        assert_eq!(stats.duration_sec, 1000);
        assert_eq!(stats.sample_count, 0);
        assert_eq!(stats.max_depth_m, 0.0);
    }

    #[test]
    fn test_gas_switch_count_by_gasmix_index() {
        let dive = create_test_dive();
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 60,
                depth_m: 10.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 120,
                depth_m: 20.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(1),
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            }, // switch 1
            SampleInput {
                t_sec: 300,
                depth_m: 30.0,
                temp_c: 16.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(1),
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 600,
                depth_m: 20.0,
                temp_c: 17.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            }, // switch 2
            SampleInput {
                t_sec: 900,
                depth_m: 5.0,
                temp_c: 19.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];
        let stats = DiveStats::compute(&dive, &samples);
        assert_eq!(stats.gas_switch_count, 2);
    }

    #[test]
    fn test_rates_single_sample() {
        let samples = vec![SampleInput {
            t_sec: 0,
            depth_m: 10.0,
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
        }];
        let (descent, ascent) = DiveStats::compute_rates(&samples);
        assert_eq!(descent, 0.0);
        assert_eq!(ascent, 0.0);
    }

    #[test]
    fn test_rates_no_bottom_time() {
        // Max depth only at one sample — no flat bottom
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
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
            },
            SampleInput {
                t_sec: 300,
                depth_m: 30.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 900,
                depth_m: 0.0,
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
            },
        ];
        let (descent, ascent) = DiveStats::compute_rates(&samples);
        // 30m / 5min = 6.0 m/min
        assert!((descent - 6.0).abs() < 0.01);
        // 30m / 10min = 3.0 m/min
        assert!((ascent - 3.0).abs() < 0.01);
    }

    #[test]
    fn test_rates_max_at_start() {
        // Max depth at t=0 → descent 0.0, ascent computed
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 20.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 600,
                depth_m: 0.0,
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
            },
        ];
        let (descent, ascent) = DiveStats::compute_rates(&samples);
        assert_eq!(descent, 0.0);
        // 20m / 10min = 2.0 m/min
        assert!((ascent - 2.0).abs() < 0.01);
    }

    #[test]
    fn test_rates_max_at_end() {
        // Max depth at last sample → descent computed, ascent 0.0
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
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
            },
            SampleInput {
                t_sec: 600,
                depth_m: 20.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];
        let (descent, ascent) = DiveStats::compute_rates(&samples);
        // 20m / 10min = 2.0 m/min
        assert!((descent - 2.0).abs() < 0.01);
        assert_eq!(ascent, 0.0);
    }

    #[test]
    fn test_rates_multi_level_dive() {
        // Profile: 0→20m→10m→30m→0m — rates should be based on 30m max
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
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
            },
            SampleInput {
                t_sec: 120,
                depth_m: 20.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 300,
                depth_m: 10.0,
                temp_c: 19.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 600,
                depth_m: 30.0,
                temp_c: 16.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 1200,
                depth_m: 0.0,
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
            },
        ];
        let (descent, ascent) = DiveStats::compute_rates(&samples);
        // Descent: 30m / 10min = 3.0 m/min (surface to first 30m at t=600)
        assert!((descent - 3.0).abs() < 0.01);
        // Ascent: 30m / 10min = 3.0 m/min (last 30m at t=600 to surface at t=1200)
        assert!((ascent - 3.0).abs() < 0.01);
    }

    #[test]
    fn test_dive_stats_exact_values() {
        let dive = create_test_dive();
        let samples = create_test_samples();
        let stats = DiveStats::compute(&dive, &samples);

        // total_time = end - start = 3600
        assert_eq!(stats.total_time_sec, 3600);
        // max_depth = 30.0 (samples 3,4)
        assert_eq!(stats.max_depth_m, 30.0);
        // avg_depth = (0+10+20+30+30+20+5+0)/8 = 14.375
        assert_eq!(stats.avg_depth_m, 14.375);
        // avg_temp = (22+20+18+16+16+17+19+21)/8 = 18.625
        assert_eq!(stats.avg_temp_c, 18.625);
        assert_eq!(stats.min_temp_c, 16.0);
        assert_eq!(stats.max_temp_c, 22.0);

        // weighted_avg_depth: dt=[60,60,180,300,300,300,300,300], weight_sum=1800
        // weighted_sum = 0*60+10*60+20*180+30*300+30*300+20*300+5*300+0*300 = 29700
        // 29700/1800 = 16.5
        assert_eq!(stats.weighted_avg_depth_m, 16.5);

        // bottom_time (deco dive): multi-signal detection finds ascent at t=900
        // (rate 2.0 m/min from 30→20m, no return to ≥15m after).
        // Walk-back: t=600 is outside 120s window → peak = t=900 itself.
        assert_eq!(stats.bottom_time_sec, 900);
        assert_eq!(stats.bottom_end_t, 900);

        // deco_obligation (all ceiling > 0): samples 3,4,5 with dt=[300,300,300] = 900
        assert_eq!(stats.deco_obligation_sec, 900);
        // deco_start_t = 0 (no ceiling > 0 after bottom_end_t=900, no gas switches)
        assert_eq!(stats.deco_start_t, 0);
        // deco_time = 0: no deco phase boundary detected
        assert_eq!(stats.deco_time_sec, 0);

        assert_eq!(stats.max_ceiling_m, 6.0);
        assert_eq!(stats.max_gf99, 80.0);
        assert_eq!(stats.gas_switch_count, 0);
        assert_eq!(stats.depth_class, DepthClass::Deep);

        // descent: 30m / (300s/60) = 6.0 m/min
        assert_eq!(stats.descent_rate_m_min, 6.0);
        // ascent: 30m / (900s/60) = 2.0 m/min
        assert_eq!(stats.ascent_rate_m_min, 2.0);
    }

    #[test]
    fn test_segment_stats_exact_values() {
        let samples = create_test_samples();
        // Segment from t=300 to t=900 captures samples 3,4,5
        let stats = SegmentStats::compute(300, 900, &samples, 0, 300);

        assert_eq!(stats.duration_sec, 600);
        assert_eq!(stats.max_depth_m, 30.0);
        // avg_depth = (30+30+20)/3
        let expected_avg = (30.0 + 30.0 + 20.0) / 3.0;
        assert!((stats.avg_depth_m - expected_avg as f32).abs() < 1e-6);
        assert_eq!(stats.min_temp_c, 16.0);
        assert_eq!(stats.max_temp_c, 17.0);
        assert_eq!(stats.sample_count, 3);
        // deco_time: end_t(900) - max(deco_start_t=300, start_t=300) = 600
        assert_eq!(stats.deco_time_sec, 600);
        assert_eq!(stats.deco_obligation_sec, 900);
    }

    #[test]
    fn test_segment_stats_deco_boundary() {
        // ceiling = 0.0 exactly must NOT count as deco (catches > → >=)
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 10.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 60,
                depth_m: 10.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];
        let stats = SegmentStats::compute(0, 60, &samples, 0, 0);
        assert_eq!(stats.deco_time_sec, 0);
    }

    #[test]
    fn test_segment_stats_single_sample() {
        // Single sample exercises dt=1 fallback
        let samples = vec![SampleInput {
            t_sec: 100,
            depth_m: 15.0,
            temp_c: 18.0,
            setpoint_ppo2: None,
            ceiling_m: Some(2.0),
            gf99: None,
            gasmix_index: None,
            ppo2: None,
            tts_sec: None,
            ndl_sec: None,
            deco_stop_depth_m: None,
            at_plus_five_tts_min: None,
        }];
        let stats = SegmentStats::compute(100, 200, &samples, 0, 100);
        assert_eq!(stats.duration_sec, 100);
        assert_eq!(stats.max_depth_m, 15.0);
        assert_eq!(stats.avg_depth_m, 15.0);
        assert_eq!(stats.min_temp_c, 18.0);
        assert_eq!(stats.max_temp_c, 18.0);
        assert_eq!(stats.sample_count, 1);
        // deco_time: end_t(200) - max(deco_start_t=100, start_t=100) = 100
        assert_eq!(stats.deco_time_sec, 100);
    }

    #[test]
    fn test_depth_class_label() {
        assert_eq!(DepthClass::Recreational.label(), "Recreational");
        assert_eq!(DepthClass::Deep.label(), "Deep");
        assert_eq!(DepthClass::Extended.label(), "Extended Range");
        assert_eq!(DepthClass::Extreme.label(), "Extreme");
    }

    #[test]
    fn test_rates_exact() {
        let samples = create_test_samples();
        let (descent, ascent) = DiveStats::compute_rates(&samples);
        // descent: 30m / 5min = exactly 6.0
        assert_eq!(descent, 6.0);
        // ascent: 30m / 15min = exactly 2.0
        assert_eq!(ascent, 2.0);
    }

    #[test]
    fn test_total_time_exact() {
        // total_time = end - start (catches - → +)
        let dive = DiveInput {
            start_time_unix: 1000,
            end_time_unix: 2500,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let stats = DiveStats::compute(&dive, &[]);
        assert_eq!(stats.total_time_sec, 1500);
    }

    #[test]
    fn test_temperature_equal_values() {
        // All samples same temp → min = max = avg (catches min/max comparison mutations)
        let dive = create_test_dive();
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 10.0,
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
            },
            SampleInput {
                t_sec: 60,
                depth_m: 10.0,
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
            },
        ];
        let stats = DiveStats::compute(&dive, &samples);
        assert_eq!(stats.min_temp_c, 20.0);
        assert_eq!(stats.max_temp_c, 20.0);
        assert_eq!(stats.avg_temp_c, 20.0);
    }

    #[test]
    fn test_segment_duration_exact() {
        // duration = end - start (catches - → +)
        let stats = SegmentStats::compute(100, 500, &[], 0, 0);
        assert_eq!(stats.duration_sec, 400);
    }

    #[test]
    fn test_dive_stats_single_sample_fallbacks() {
        // Single sample exercises dt=1 fallback for weighted avg and bottom time
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 60,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let samples = vec![SampleInput {
            t_sec: 0,
            depth_m: 10.0,
            temp_c: 18.0,
            setpoint_ppo2: None,
            ceiling_m: Some(2.0),
            gf99: Some(50.0),
            gasmix_index: Some(0),
            ppo2: None,
            tts_sec: None,
            ndl_sec: None,
            deco_stop_depth_m: None,
            at_plus_five_tts_min: None,
        }];
        let stats = DiveStats::compute(&dive, &samples);
        // Single sample: weighted_avg = depth (weight=1, sum=10*1=10, 10/1=10)
        assert_eq!(stats.weighted_avg_depth_m, 10.0);
        assert_eq!(stats.avg_depth_m, 10.0);
        // Deco dive (ceiling=2>0), single sample at max depth 10m → bottom_time = t_sec = 0
        assert_eq!(stats.bottom_time_sec, 0);
        // ceiling > 0, dt=1 fallback; t=0 <= bottom_end_t=0 → obligation only
        assert_eq!(stats.deco_obligation_sec, 1);
        assert_eq!(stats.deco_time_sec, 0);
        assert_eq!(stats.max_gf99, 50.0);
        assert_eq!(stats.max_ceiling_m, 2.0);
    }

    #[test]
    fn test_depth_class_boundaries() {
        // Exact boundaries: 18.0 → Recreational, 18.01 → Deep
        assert_eq!(DepthClass::from_depth_m(18.0), DepthClass::Recreational);
        assert_eq!(DepthClass::from_depth_m(18.01), DepthClass::Deep);
        assert_eq!(DepthClass::from_depth_m(40.0), DepthClass::Deep);
        assert_eq!(DepthClass::from_depth_m(40.01), DepthClass::Extended);
        assert_eq!(DepthClass::from_depth_m(60.0), DepthClass::Extended);
        assert_eq!(DepthClass::from_depth_m(60.01), DepthClass::Extreme);
        assert_eq!(DepthClass::from_depth_m(0.0), DepthClass::Recreational);
    }

    #[test]
    fn test_gas_switch_count_setpoint_noise_ignored() {
        // CCR dive with fluctuating setpoint but constant gasmix_index — no gas switches
        let dive = create_test_dive();
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: Some(0.7),
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 60,
                depth_m: 10.0,
                temp_c: 20.0,
                setpoint_ppo2: Some(1.0),
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 120,
                depth_m: 20.0,
                temp_c: 18.0,
                setpoint_ppo2: Some(1.3),
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 300,
                depth_m: 30.0,
                temp_c: 16.0,
                setpoint_ppo2: Some(1.3),
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 600,
                depth_m: 20.0,
                temp_c: 17.0,
                setpoint_ppo2: Some(1.0),
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 900,
                depth_m: 5.0,
                temp_c: 19.0,
                setpoint_ppo2: Some(0.7),
                ceiling_m: None,
                gf99: None,
                gasmix_index: Some(0),
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];
        let stats = DiveStats::compute(&dive, &samples);
        assert_eq!(stats.gas_switch_count, 0);
    }

    // ── Round 2: kill remaining mutants ──────────────────────

    #[test]
    fn test_deco_time_last_sample_has_ceiling() {
        // Last sample has ceiling > 0, exercises the `else if i > 0` fallback
        // for deco_dt (line 171-172). With `i > 0` → `i < 0`, dt would be 1 instead.
        let dive = create_test_dive();
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 10.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 100,
                depth_m: 20.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 400,
                depth_m: 15.0,
                temp_c: 19.0,
                setpoint_ppo2: None,
                ceiling_m: Some(2.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];
        let stats = DiveStats::compute(&dive, &samples);
        // bottom_end_t = 100 (fallback: 80% of 20m = 16m, last sample ≥ 16m at t=100)
        // deco_start_t = 400 (first ceiling > 0 after bottom_end_t)
        // deco_obligation: ceiling > 0 at t=100 (dt=300) + t=400 (dt=300) = 600
        assert_eq!(stats.deco_obligation_sec, 600);
        // deco_time: total_time(3600) - deco_start_t(400) = 3200
        assert_eq!(stats.deco_time_sec, 3200);
    }

    #[test]
    fn test_bottom_time_non_deco_dive_is_zero() {
        // Non-deco dive (no ceiling data) → bottom_time_sec = 0
        let dive = create_test_dive();
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
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
            },
            SampleInput {
                t_sec: 100,
                depth_m: 10.0,
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
            },
            SampleInput {
                t_sec: 400,
                depth_m: 15.0,
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
            },
        ];
        let stats = DiveStats::compute(&dive, &samples);
        assert_eq!(stats.bottom_time_sec, 0);
    }

    #[test]
    fn test_bottom_time_non_deco_with_ceiling_zero() {
        // All ceiling = 0.0 (no deco obligation) → bottom_time_sec = 0
        let dive = create_test_dive();
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 20.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 600,
                depth_m: 20.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];
        let stats = DiveStats::compute(&dive, &samples);
        assert_eq!(stats.bottom_time_sec, 0);
    }

    #[test]
    fn test_rates_nonzero_start_time() {
        // Samples starting at t=60 (not t=0) to differentiate - from + in rate calcs
        // Line 311: samples[first_max_idx].t_sec - samples[0].t_sec
        // If mutated to +: 360 + 60 = 420 vs correct 360 - 60 = 300
        let samples = vec![
            SampleInput {
                t_sec: 60,
                depth_m: 0.0,
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
            },
            SampleInput {
                t_sec: 360,
                depth_m: 30.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 960,
                depth_m: 0.0,
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
            },
        ];
        let (descent, ascent) = DiveStats::compute_rates(&samples);
        // descent: 30m / ((360-60)/60 min) = 30/5 = 6.0
        assert_eq!(descent, 6.0);
        // ascent: (30-0)m / ((960-360)/60 min) = 30/10 = 3.0
        assert_eq!(ascent, 3.0);
    }

    #[test]
    fn test_rates_nonzero_end_depth() {
        // Last sample has non-zero depth to differentiate - from + in ascent
        // Line 326: samples[last_max_idx].depth_m - last.depth_m
        // If mutated to +: 30+5 = 35, correct: 30-5 = 25
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
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
            },
            SampleInput {
                t_sec: 300,
                depth_m: 30.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 900,
                depth_m: 5.0,
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
            },
        ];
        let (descent, ascent) = DiveStats::compute_rates(&samples);
        // descent: 30m / 5min = 6.0
        assert_eq!(descent, 6.0);
        // ascent: (30-5)m / 10min = 2.5
        assert_eq!(ascent, 2.5);
    }

    #[test]
    fn test_segment_stats_last_sample_with_ceiling() {
        // SegmentStats: last sample has ceiling > 0 (exercises else-if fallback)
        let samples = vec![
            SampleInput {
                t_sec: 100,
                depth_m: 20.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 400,
                depth_m: 15.0,
                temp_c: 19.0,
                setpoint_ppo2: None,
                ceiling_m: Some(2.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];
        let stats = SegmentStats::compute(100, 400, &samples, 0, 100);
        // deco_time: end_t(400) - max(deco_start_t=100, start_t=100) = 300
        assert_eq!(stats.deco_time_sec, 300);
        assert_eq!(stats.deco_obligation_sec, 600);
        assert_eq!(stats.sample_count, 2);
    }

    #[test]
    fn test_segment_stats_max_depth_equal_values() {
        // Two samples with same depth: max should still be correct (catches > → >=)
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 25.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 60,
                depth_m: 25.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];
        let stats = SegmentStats::compute(0, 60, &samples, 0, 0);
        assert_eq!(stats.max_depth_m, 25.0);
        assert_eq!(stats.min_temp_c, 18.0);
        assert_eq!(stats.max_temp_c, 18.0);
    }

    // ── Bottom time algorithm tests ──────────────────────────

    #[test]
    fn test_bottom_time_deco_dive_ends_at_last_max_depth() {
        // Profile: descend to 40m, stay, ascend to 6m deco stop, surface
        // Bottom time = t_sec of last sample at ≥ 39m
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 3600,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 180,
                depth_m: 40.0,
                temp_c: 16.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 900,
                depth_m: 40.0,
                temp_c: 16.0,
                setpoint_ppo2: None,
                ceiling_m: Some(6.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 1200,
                depth_m: 40.0,
                temp_c: 16.0,
                setpoint_ppo2: None,
                ceiling_m: Some(9.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            // Ascent begins here — leaves working depth
            SampleInput {
                t_sec: 1500,
                depth_m: 21.0,
                temp_c: 17.0,
                setpoint_ppo2: None,
                ceiling_m: Some(6.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 1800,
                depth_m: 6.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 2400,
                depth_m: 3.0,
                temp_c: 19.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 2700,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];
        let stats = DiveStats::compute(&dive, &samples);
        // Multi-signal: ascent at t=1500 (rate 3.8 m/min from 40→21m).
        // Diver never returns to ≥20m (50% of 40m) after t=1500, so confirmed.
        // Walk-back: t=1200 outside 120s window → peak = t=1500 itself.
        assert_eq!(stats.bottom_end_t, 1500);
        assert_eq!(stats.bottom_time_sec, 1500);
        // deco_start_t: OC fallback → first ceiling > 0 after t=1500 = t=1800 (ceil=3)
        assert_eq!(stats.deco_start_t, 1800);
        // deco_obligation: all ceiling>0 (t=900,1200,1500,1800) dt=[300,300,300,600] = 1500
        assert_eq!(stats.deco_obligation_sec, 1500);
        // deco_time: total_time(3600) - deco_start_t(1800) = 1800
        assert_eq!(stats.deco_time_sec, 1800);
    }

    #[test]
    fn test_bottom_time_multi_level_deco() {
        // Multi-level: 30m → 25m → back to 30m → ascent to deco stops
        // Bottom time = when diver leaves and never returns to ≥15m (50% of 30m)
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 3000,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 120,
                depth_m: 30.0,
                temp_c: 16.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 300,
                depth_m: 25.0,
                temp_c: 17.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            // Return to max depth
            SampleInput {
                t_sec: 600,
                depth_m: 30.0,
                temp_c: 16.0,
                setpoint_ppo2: None,
                ceiling_m: Some(6.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            // Leave bottom for good
            SampleInput {
                t_sec: 900,
                depth_m: 15.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 1200,
                depth_m: 5.0,
                temp_c: 19.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 1500,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];
        let stats = DiveStats::compute(&dive, &samples);
        // Multi-signal: ascent detected at t=900 (rate 3.0 m/min), no stabilization after.
        // Walk-back peak is at t=900 itself (no samples in 120s window before).
        assert_eq!(stats.bottom_end_t, 900);
        assert_eq!(stats.bottom_time_sec, 900);
    }

    #[test]
    fn test_bottom_time_depth_oscillation_within_threshold() {
        // Diver at 29.5-30m (both within 1m of max=30) — bottom time includes full phase
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 2000,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 120,
                depth_m: 30.0,
                temp_c: 16.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            // Slight shallowing due to surge — still in working depth band
            SampleInput {
                t_sec: 300,
                depth_m: 29.5,
                temp_c: 16.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 600,
                depth_m: 29.2,
                temp_c: 16.0,
                setpoint_ppo2: None,
                ceiling_m: Some(6.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            // Ascent begins
            SampleInput {
                t_sec: 900,
                depth_m: 15.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 1200,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];
        let stats = DiveStats::compute(&dive, &samples);
        // Multi-signal: ascent detected at t=900 (rate 2.84 m/min), confirmed.
        // Bottom includes the full oscillation phase at ~29-30m.
        assert_eq!(stats.bottom_end_t, 900);
        assert_eq!(stats.bottom_time_sec, 900);
    }

    // ── Deco time rework tests ──────────────────────────────

    #[test]
    fn test_ascent_phase_deco_split() {
        // Deep dive: ceiling > 0 both at depth and during ascent
        // Verify deco_obligation vs deco_time split
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 3600,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            // Descend to 50m
            SampleInput {
                t_sec: 180,
                depth_m: 50.0,
                temp_c: 14.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(0),
                ndl_sec: Some(300),
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            // At depth — ceiling builds (accumulating deco at bottom)
            SampleInput {
                t_sec: 600,
                depth_m: 50.0,
                temp_c: 14.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: Some(70.0),
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(300),
                ndl_sec: None,
                deco_stop_depth_m: Some(3.0),
                at_plus_five_tts_min: None,
            },
            // Still at depth — more deco obligation
            SampleInput {
                t_sec: 1200,
                depth_m: 50.0,
                temp_c: 14.0,
                setpoint_ppo2: None,
                ceiling_m: Some(6.0),
                gf99: Some(85.0),
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(600),
                ndl_sec: None,
                deco_stop_depth_m: Some(6.0),
                at_plus_five_tts_min: None,
            },
            // Begin ascent — still has ceiling
            SampleInput {
                t_sec: 1500,
                depth_m: 21.0,
                temp_c: 16.0,
                setpoint_ppo2: None,
                ceiling_m: Some(6.0),
                gf99: Some(80.0),
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(480),
                ndl_sec: None,
                deco_stop_depth_m: Some(6.0),
                at_plus_five_tts_min: None,
            },
            // Deco stop at 6m
            SampleInput {
                t_sec: 1800,
                depth_m: 6.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: Some(75.0),
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(180),
                ndl_sec: None,
                deco_stop_depth_m: Some(3.0),
                at_plus_five_tts_min: None,
            },
            // Deco stop at 3m
            SampleInput {
                t_sec: 2400,
                depth_m: 3.0,
                temp_c: 19.0,
                setpoint_ppo2: None,
                ceiling_m: Some(1.0),
                gf99: Some(60.0),
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(60),
                ndl_sec: None,
                deco_stop_depth_m: Some(3.0),
                at_plus_five_tts_min: None,
            },
            // Surface
            SampleInput {
                t_sec: 2700,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: Some(40.0),
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(0),
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];

        let stats = DiveStats::compute(&dive, &samples);

        // Multi-signal: ascent at t=1500 (rate 5.8 m/min), confirmed.
        assert_eq!(stats.bottom_end_t, 1500);
        assert_eq!(stats.bottom_time_sec, 1500);
        // deco_start_t: first ceiling > 0 after t=1500 → t=1800
        assert_eq!(stats.deco_start_t, 1800);
        assert_eq!(stats.max_tts_sec, 600);

        // deco_obligation: ceiling > 0 at t=600,1200,1500,1800,2400
        // dt: 600,300,300,600,300 = 2100
        assert_eq!(stats.deco_obligation_sec, 2100);

        // deco_time: total_time(3600) - deco_start_t(1800) = 1800
        assert_eq!(stats.deco_time_sec, 1800);
    }

    #[test]
    fn test_tts_tracking() {
        // Verify max_tts_sec is correctly tracked
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 1200,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(0),
                ndl_sec: Some(600),
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 300,
                depth_m: 30.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(120),
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: Some(5),
            },
            SampleInput {
                t_sec: 600,
                depth_m: 30.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: Some(6.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(480),
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: Some(12),
            },
            SampleInput {
                t_sec: 900,
                depth_m: 5.0,
                temp_c: 19.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(60),
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];

        let stats = DiveStats::compute(&dive, &samples);
        // Peak TTS is 480 at t=600
        assert_eq!(stats.max_tts_sec, 480);
    }

    #[test]
    fn test_all_ceiling_at_depth_no_ascent() {
        // Ceiling > 0 only at depth, never ascends — deco_time=0, deco_obligation>0
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 1200,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 120,
                depth_m: 40.0,
                temp_c: 14.0,
                setpoint_ppo2: None,
                ceiling_m: Some(0.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            // At depth with ceiling, still at max depth
            SampleInput {
                t_sec: 600,
                depth_m: 40.0,
                temp_c: 14.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(120),
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 900,
                depth_m: 40.0,
                temp_c: 14.0,
                setpoint_ppo2: None,
                ceiling_m: Some(6.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(300),
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];

        let stats = DiveStats::compute(&dive, &samples);
        // max_depth=40, threshold=39. Last sample at >=39 is t=900
        assert_eq!(stats.bottom_time_sec, 900);
        // All ceiling > 0 samples at depth (t=600, t=900), both <= bottom_end_t
        // dt: 300, 300 = 600
        assert_eq!(stats.deco_obligation_sec, 600);
        assert_eq!(stats.deco_time_sec, 0);
        assert_eq!(stats.max_tts_sec, 300);
    }

    #[test]
    fn test_no_tts_data_returns_zero() {
        // Dive with no TTS data (all None) → max_tts_sec = 0
        let dive = create_test_dive();
        let samples = create_test_samples();
        let stats = DiveStats::compute(&dive, &samples);
        assert_eq!(stats.max_tts_sec, 0);
    }

    #[test]
    fn test_segment_stats_with_bottom_end_t() {
        // Segment spanning bottom and ascent phases — verify deco split
        let samples = vec![
            SampleInput {
                t_sec: 300,
                depth_m: 40.0,
                temp_c: 14.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(120),
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 600,
                depth_m: 40.0,
                temp_c: 14.0,
                setpoint_ppo2: None,
                ceiling_m: Some(6.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(300),
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 900,
                depth_m: 10.0,
                temp_c: 18.0,
                setpoint_ppo2: None,
                ceiling_m: Some(3.0),
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: Some(60),
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];

        // dive_bottom_end_t=600, dive_deco_start_t=600
        let stats = SegmentStats::compute(300, 900, &samples, 600, 600);

        // deco_obligation: all 3 samples have ceiling>0, dt=[300,300,300]=900
        assert_eq!(stats.deco_obligation_sec, 900);
        // deco_time: end_t(900) - max(deco_start_t=600, start_t=300) = 300
        assert_eq!(stats.deco_time_sec, 300);
        assert_eq!(stats.max_tts_sec, 300);
    }

    #[test]
    fn test_rec_dive_no_deco_metrics() {
        // Recreational dive with no ceiling data: both deco metrics = 0
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 2400,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let samples = vec![
            SampleInput {
                t_sec: 0,
                depth_m: 0.0,
                temp_c: 22.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: Some(600),
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 600,
                depth_m: 18.0,
                temp_c: 20.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: Some(300),
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
            SampleInput {
                t_sec: 1200,
                depth_m: 0.0,
                temp_c: 22.0,
                setpoint_ppo2: None,
                ceiling_m: None,
                gf99: None,
                gasmix_index: None,
                ppo2: None,
                tts_sec: None,
                ndl_sec: None,
                deco_stop_depth_m: None,
                at_plus_five_tts_min: None,
            },
        ];

        let stats = DiveStats::compute(&dive, &samples);
        assert_eq!(stats.deco_time_sec, 0);
        assert_eq!(stats.deco_obligation_sec, 0);
        assert_eq!(stats.max_tts_sec, 0);
        assert_eq!(stats.bottom_time_sec, 0);
    }

    // ── Three-phase deco model tests ─────────────────────────

    /// Helper: create a sample with minimal fields.
    fn sample(t_sec: i32, depth_m: f32, ceiling_m: Option<f32>) -> SampleInput {
        SampleInput {
            t_sec,
            depth_m,
            temp_c: 15.0,
            setpoint_ppo2: None,
            ceiling_m,
            gf99: None,
            gasmix_index: None,
            ppo2: None,
            tts_sec: None,
            ndl_sec: None,
            deco_stop_depth_m: None,
            at_plus_five_tts_min: None,
        }
    }

    fn sample_with_gas(
        t_sec: i32,
        depth_m: f32,
        ceiling_m: Option<f32>,
        gasmix_index: i32,
    ) -> SampleInput {
        SampleInput {
            gasmix_index: Some(gasmix_index),
            ..sample(t_sec, depth_m, ceiling_m)
        }
    }

    fn sample_with_delta5(
        t_sec: i32,
        depth_m: f32,
        ceiling_m: Option<f32>,
        at_plus_five: i32,
    ) -> SampleInput {
        SampleInput {
            at_plus_five_tts_min: Some(at_plus_five),
            ..sample(t_sec, depth_m, ceiling_m)
        }
    }

    #[test]
    fn test_multi_level_bottom_end_t() {
        // 58m → 48m plateau (7 min) → stops
        // Old algorithm: bottom_end_t near 58m. New: should include 48m plateau.
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 4200,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let mut samples = Vec::new();
        // Descent to 58m over 3 min (10s intervals)
        for t in (0..=180).step_by(10) {
            let depth = 58.0 * (t as f32 / 180.0);
            samples.push(sample(t, depth, Some(0.0)));
        }
        // At 58m for 10 min
        for t in (190..=780).step_by(10) {
            samples.push(sample(t, 58.0, Some(3.0)));
        }
        // Move to 48m over 1 min (level change)
        for t in (790..=840).step_by(10) {
            let depth = 58.0 - 10.0 * ((t - 780) as f32 / 60.0);
            samples.push(sample(t, depth, Some(3.0)));
        }
        // Plateau at 48m for 7 min
        for t in (850..=1270).step_by(10) {
            samples.push(sample(t, 48.0, Some(6.0)));
        }
        // Ascent from 48m to 21m over 3 min
        for t in (1280..=1460).step_by(10) {
            let depth = 48.0 - 27.0 * ((t - 1270) as f32 / 180.0);
            samples.push(sample(t, depth, Some(6.0)));
        }
        // Deco stops at 6m
        for t in (1470..=2100).step_by(10) {
            samples.push(sample(t, 6.0, Some(3.0)));
        }
        // Surface
        for t in (2110..=2400).step_by(10) {
            samples.push(sample(t, 0.0, Some(0.0)));
        }

        let stats = DiveStats::compute(&dive, &samples);

        // The 48m plateau should be included in bottom phase.
        // bottom_end_t should be near end of 48m plateau (~1270), not at 58m departure.
        assert!(
            stats.bottom_end_t >= 1200,
            "bottom_end_t {} should be >= 1200 (end of 48m plateau)",
            stats.bottom_end_t
        );
        assert!(
            stats.bottom_end_t <= 1460,
            "bottom_end_t {} should be <= 1460 (before deco stops)",
            stats.bottom_end_t
        );
        // deco_start_t should be at or after bottom_end_t
        assert!(stats.deco_start_t >= stats.bottom_end_t);
        // ascent_time = deco_start_t - bottom_end_t
        assert_eq!(
            stats.ascent_time_sec,
            stats.deco_start_t - stats.bottom_end_t
        );
        // deco_time should be > 0 (deco stops at 6m)
        assert!(stats.deco_time_sec > 0);
        // deco_time = total_time - deco_start_t, includes all time from deco_start to surface
        assert!(stats.deco_time_sec >= stats.deco_obligation_sec);
    }

    #[test]
    fn test_three_level_bottom_end_t() {
        // 58m → 48m → 42m → stops
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 5400,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let mut samples = Vec::new();
        // Descent 3 min
        for t in (0..=180).step_by(10) {
            samples.push(sample(t, 58.0 * t as f32 / 180.0, Some(0.0)));
        }
        // 58m for 8 min
        for t in (190..=670).step_by(10) {
            samples.push(sample(t, 58.0, Some(3.0)));
        }
        // 48m for 5 min
        for t in (680..=980).step_by(10) {
            samples.push(sample(t, 48.0, Some(6.0)));
        }
        // 42m for 5 min
        for t in (990..=1290).step_by(10) {
            samples.push(sample(t, 42.0, Some(6.0)));
        }
        // Final ascent to stops
        for t in (1300..=1500).step_by(10) {
            let depth = 42.0 - 36.0 * ((t - 1290) as f32 / 210.0);
            samples.push(sample(t, depth, Some(6.0)));
        }
        // Stops at 6m
        for t in (1510..=2400).step_by(10) {
            samples.push(sample(t, 6.0, Some(3.0)));
        }
        samples.push(sample(2700, 0.0, Some(0.0)));

        let stats = DiveStats::compute(&dive, &samples);
        // bottom_end_t should be near end of 42m phase (~1290)
        assert!(
            stats.bottom_end_t >= 1200,
            "bottom_end_t {} should capture all three levels",
            stats.bottom_end_t
        );
    }

    #[test]
    fn test_single_level_regression() {
        // Simple 30m dive, no multi-level. Verify reasonable bottom_end_t.
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 3600,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let mut samples = Vec::new();
        // Descent 2 min
        for t in (0..=120).step_by(10) {
            samples.push(sample(t, 30.0 * t as f32 / 120.0, Some(0.0)));
        }
        // At 30m for 20 min
        for t in (130..=1320).step_by(10) {
            samples.push(sample(t, 30.0, Some(3.0)));
        }
        // Ascent to 6m over 2.5 min
        for t in (1330..=1470).step_by(10) {
            let depth = 30.0 - 24.0 * ((t - 1320) as f32 / 150.0);
            samples.push(sample(t, depth, Some(3.0)));
        }
        // Stops at 6m
        for t in (1480..=2100).step_by(10) {
            samples.push(sample(t, 6.0, Some(3.0)));
        }
        samples.push(sample(2400, 0.0, Some(0.0)));

        let stats = DiveStats::compute(&dive, &samples);
        // bottom_end_t should be near end of 30m phase
        assert!(
            stats.bottom_end_t >= 1200 && stats.bottom_end_t <= 1470,
            "bottom_end_t {} should be near end of 30m phase",
            stats.bottom_end_t
        );
        assert!(stats.deco_time_sec > 0);
    }

    #[test]
    fn test_bottom_end_override() {
        // Override in DiveInput should be used directly
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 3600,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: Some(999),
            deco_start_t_override_sec: None,
        };
        let samples = vec![
            sample(0, 0.0, Some(0.0)),
            sample(120, 40.0, Some(3.0)),
            sample(600, 40.0, Some(6.0)),
            sample(1200, 6.0, Some(3.0)),
            sample(1800, 0.0, Some(0.0)),
        ];
        let stats = DiveStats::compute(&dive, &samples);
        assert_eq!(stats.bottom_end_t, 999);
        assert_eq!(stats.bottom_time_sec, 999);
    }

    #[test]
    fn test_deco_start_override() {
        // Override in DiveInput should be used directly
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 3600,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: Some(1500),
        };
        let samples = vec![
            sample(0, 0.0, Some(0.0)),
            sample(120, 40.0, Some(3.0)),
            sample(600, 40.0, Some(6.0)),
            sample(1200, 6.0, Some(3.0)),
            sample(1800, 0.0, Some(0.0)),
        ];
        let stats = DiveStats::compute(&dive, &samples);
        assert_eq!(stats.deco_start_t, 1500);
        // deco_time = total(3600) - deco_start(1500) = 2100
        assert_eq!(stats.deco_time_sec, 2100);
    }

    #[test]
    fn test_delta5_defers_trigger() {
        // Ascent with strongly positive Δ+5 should not trigger bottom_end
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 4200,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let mut samples = Vec::new();
        // Descent to 50m
        for t in (0..=120).step_by(10) {
            samples.push(sample_with_delta5(t, 50.0 * t as f32 / 120.0, Some(0.0), 0));
        }
        // At 50m
        for t in (130..=600).step_by(10) {
            samples.push(sample_with_delta5(t, 50.0, Some(3.0), 10));
        }
        // Move to 40m with high Δ+5 (still on-gassing → should not trigger)
        for t in (610..=720).step_by(10) {
            let depth = 50.0 - 10.0 * ((t - 600) as f32 / 120.0);
            samples.push(sample_with_delta5(t, depth, Some(3.0), 8));
        }
        // Plateau at 40m with high Δ+5
        for t in (730..=1200).step_by(10) {
            samples.push(sample_with_delta5(t, 40.0, Some(6.0), 7));
        }
        // Final ascent with low Δ+5 (off-gassing)
        for t in (1210..=1500).step_by(10) {
            let depth = 40.0 - 34.0 * ((t - 1200) as f32 / 300.0);
            samples.push(sample_with_delta5(t, depth, Some(6.0), 1));
        }
        // Stops at 6m
        for t in (1510..=2400).step_by(10) {
            samples.push(sample_with_delta5(t, 6.0, Some(3.0), 0));
        }
        samples.push(sample(2700, 0.0, Some(0.0)));

        let stats = DiveStats::compute(&dive, &samples);
        // The 50→40m transition should be deferred due to Δ+5,
        // bottom_end_t should be near end of 40m phase (~1200)
        assert!(
            stats.bottom_end_t >= 1100,
            "bottom_end_t {} should be deferred past 50→40m transition",
            stats.bottom_end_t
        );
    }

    #[test]
    fn test_fallback_80_percent() {
        // Very gradual ascent: rate stays below 1.5 m/min → fallback to 80% threshold
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 7200,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let mut samples = Vec::new();
        // Descent to 50m
        for t in (0..=60).step_by(10) {
            samples.push(sample(t, 50.0 * t as f32 / 60.0, Some(0.0)));
        }
        // Very slow ascent: 50m → 0m over 100 min = 0.5 m/min (below 1.5 threshold)
        for t in (70..=6070).step_by(10) {
            let depth = 50.0 * (1.0 - ((t - 60) as f32 / 6000.0));
            let ceil = if depth > 30.0 { Some(3.0) } else { Some(0.0) };
            samples.push(sample(t, depth, ceil));
        }
        samples.push(sample(6300, 0.0, Some(0.0)));

        let stats = DiveStats::compute(&dive, &samples);
        // With gradual ascent, the algorithm should trigger or fall back to 80%
        assert!(
            stats.bottom_end_t > 0,
            "should produce non-zero bottom_end_t"
        );
        // bottom_end_t should be before the last sample
        assert!(
            stats.bottom_end_t < 6300,
            "bottom_end_t {} should be before surface",
            stats.bottom_end_t
        );
    }

    #[test]
    fn test_no_deco_no_bottom_end() {
        // Recreational dive → bottom_end_t = 0
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 3600,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let samples = vec![
            sample(0, 0.0, None),
            sample(120, 18.0, None),
            sample(1800, 18.0, None),
            sample(2100, 0.0, None),
        ];
        let stats = DiveStats::compute(&dive, &samples);
        assert_eq!(stats.bottom_end_t, 0);
        assert_eq!(stats.deco_start_t, 0);
        assert_eq!(stats.ascent_time_sec, 0);
    }

    #[test]
    fn test_oc_deco_start_at_gas_switch() {
        // OC dive with gas switch during ascent → deco_start_t at switch
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 4200,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let mut samples = Vec::new();
        // Descent on gas 0
        for t in (0..=120).step_by(10) {
            samples.push(sample_with_gas(t, 40.0 * t as f32 / 120.0, Some(0.0), 0));
        }
        // At 40m on gas 0
        for t in (130..=900).step_by(10) {
            samples.push(sample_with_gas(t, 40.0, Some(3.0), 0));
        }
        // Ascent on gas 0
        for t in (910..=1100).step_by(10) {
            let depth = 40.0 - 19.0 * ((t - 900) as f32 / 200.0);
            samples.push(sample_with_gas(t, depth, Some(6.0), 0));
        }
        // Gas switch to gas 1 at 21m (deco gas)
        let gas_switch_t = 1110;
        for t in (gas_switch_t..=1800).step_by(10) {
            samples.push(sample_with_gas(t, 6.0, Some(3.0), 1));
        }
        samples.push(sample_with_gas(2100, 0.0, Some(0.0), 1));

        let stats = DiveStats::compute(&dive, &samples);
        // deco_start_t should be at or very near gas switch time
        assert_eq!(
            stats.deco_start_t, gas_switch_t,
            "OC deco_start_t should be at gas switch"
        );
    }

    #[test]
    fn test_ccr_deco_start_at_first_stop() {
        // CCR dive → deco_start_t when depth approaches ceiling and levels off
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 4200,
            bottom_time_sec: 0,
            is_ccr: true,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let mut samples = Vec::new();
        // Descent
        for t in (0..=120).step_by(10) {
            samples.push(sample(t, 50.0 * t as f32 / 120.0, Some(0.0)));
        }
        // At 50m
        for t in (130..=900).step_by(10) {
            samples.push(sample(t, 50.0, Some(3.0)));
        }
        // Ascent
        for t in (910..=1200).step_by(10) {
            let depth = 50.0 - 41.0 * ((t - 900) as f32 / 300.0);
            samples.push(sample(t, depth, Some(9.0)));
        }
        // Arrive at first stop: 9m, ceiling=9m, level off
        let first_stop_start = 1210;
        for t in (first_stop_start..=1800).step_by(10) {
            samples.push(sample(t, 9.0, Some(9.0)));
        }
        // Second stop at 6m
        for t in (1810..=2400).step_by(10) {
            samples.push(sample(t, 6.0, Some(6.0)));
        }
        samples.push(sample(2700, 0.0, Some(0.0)));

        let stats = DiveStats::compute(&dive, &samples);
        // For CCR, deco_start_t should be when diver arrives at first stop
        // depth (9m) is within 3m of ceiling (9m) and levels off
        // deco_start_t should be near first stop (within 60s of arrival)
        assert!(
            stats.deco_start_t >= first_stop_start - 60
                && stats.deco_start_t <= first_stop_start + 30,
            "CCR deco_start_t {} should be near first stop arrival {}",
            stats.deco_start_t,
            first_stop_start
        );
    }

    #[test]
    fn test_ascent_time_between_boundaries() {
        // Verify ascent_time_sec = deco_start_t - bottom_end_t
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 4200,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let mut samples = Vec::new();
        for t in (0..=120).step_by(10) {
            samples.push(sample_with_gas(t, 40.0 * t as f32 / 120.0, Some(0.0), 0));
        }
        for t in (130..=900).step_by(10) {
            samples.push(sample_with_gas(t, 40.0, Some(3.0), 0));
        }
        for t in (910..=1100).step_by(10) {
            let depth = 40.0 - 19.0 * ((t - 900) as f32 / 200.0);
            samples.push(sample_with_gas(t, depth, Some(6.0), 0));
        }
        // Gas switch at 21m
        for t in (1110..=1800).step_by(10) {
            samples.push(sample_with_gas(t, 6.0, Some(3.0), 1));
        }
        samples.push(sample_with_gas(2100, 0.0, Some(0.0), 1));

        let stats = DiveStats::compute(&dive, &samples);
        assert_eq!(
            stats.ascent_time_sec,
            stats.deco_start_t - stats.bottom_end_t
        );
        assert!(stats.ascent_time_sec > 0);
    }

    #[test]
    fn test_deco_time_counts_from_deco_start() {
        // Verify deco_time_sec only counts ceiling > 0 after deco_start_t
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 4200,
            bottom_time_sec: 0,
            is_ccr: false,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let mut samples = Vec::new();
        // Descent with gas 0
        for t in (0..=120).step_by(10) {
            samples.push(sample_with_gas(t, 40.0 * t as f32 / 120.0, Some(0.0), 0));
        }
        // At depth with ceiling (obligation at depth)
        for t in (130..=900).step_by(10) {
            samples.push(sample_with_gas(t, 40.0, Some(6.0), 0));
        }
        // Ascent on gas 0
        for t in (910..=1100).step_by(10) {
            let depth = 40.0 - 34.0 * ((t - 900) as f32 / 200.0);
            samples.push(sample_with_gas(t, depth, Some(6.0), 0));
        }
        // Gas switch to gas 1, stops at 6m
        for t in (1110..=1800).step_by(10) {
            samples.push(sample_with_gas(t, 6.0, Some(3.0), 1));
        }
        samples.push(sample_with_gas(2100, 0.0, Some(0.0), 1));

        let stats = DiveStats::compute(&dive, &samples);
        // deco_time = total_time - deco_start_t, includes all time from deco_start to surface
        assert!(
            stats.deco_time_sec >= stats.deco_obligation_sec,
            "deco_time {} should be >= obligation {} (deco_time is all time from deco_start)",
            stats.deco_time_sec,
            stats.deco_obligation_sec
        );
        assert!(stats.deco_time_sec > 0);
    }

    #[test]
    fn test_ccr_multi_level_real_profile() {
        // Simulates a CCR dive: descent to 57m, work at 57m, level change to 46m
        // (just below 80% of 57), then continuous ascent to deco stops.
        // This is the pattern that caused the original bug: the 46m plateau
        // readings were below the 80% fallback threshold.
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 4500,
            bottom_time_sec: 0,
            is_ccr: true,
            bottom_end_t_override_sec: None,
            deco_start_t_override_sec: None,
        };
        let mut samples = Vec::new();
        // Descent to 57m over 3 min (10s intervals)
        for t in (0..=180).step_by(10) {
            let depth = 57.0 * (t as f32 / 180.0);
            let ceil = if depth > 40.0 { Some(3.0) } else { Some(0.0) };
            samples.push(sample(t, depth, ceil));
        }
        // At 57m for 10 min
        for t in (190..=780).step_by(10) {
            samples.push(sample(t, 57.0, Some(6.0)));
        }
        // Transition 57m → 46m over 1 min (level change)
        for t in (790..=840).step_by(10) {
            let depth = 57.0 - 11.0 * ((t - 780) as f32 / 60.0);
            samples.push(sample(t, depth, Some(9.0)));
        }
        // At 46m for 7 min (note: 46m < 80% of 57m = 45.6m by design)
        for t in (850..=1270).step_by(10) {
            samples.push(sample(t, 46.0, Some(12.0)));
        }
        // Ascent from 46m to 21m over 3 min
        for t in (1280..=1460).step_by(10) {
            let depth = 46.0 - 25.0 * ((t - 1270) as f32 / 190.0);
            samples.push(sample(t, depth, Some(15.0)));
        }
        // Deco stops at 21m
        for t in (1470..=1800).step_by(10) {
            samples.push(sample(t, 21.0, Some(18.0)));
        }
        // Deco stops at 9m
        for t in (1810..=2400).step_by(10) {
            samples.push(sample(t, 9.0, Some(9.0)));
        }
        // Deco stops at 6m
        for t in (2410..=3600).step_by(10) {
            samples.push(sample(t, 6.0, Some(3.0)));
        }
        // Surface
        for t in (3610..=4200).step_by(10) {
            samples.push(sample(t, 0.0, Some(0.0)));
        }

        let stats = DiveStats::compute(&dive, &samples);

        // bottom_end_t should capture the 46m plateau (end ~1270)
        assert!(
            stats.bottom_end_t >= 1200 && stats.bottom_end_t <= 1460,
            "bottom_end_t {} should be near end of 46m plateau",
            stats.bottom_end_t
        );
        // deco_start_t should be detected (CCR first stop)
        assert!(
            stats.deco_start_t > stats.bottom_end_t,
            "deco_start_t {} should be after bottom_end_t {}",
            stats.deco_start_t,
            stats.bottom_end_t
        );
        // deco_time should be > 0
        assert!(
            stats.deco_time_sec > 0,
            "deco_time should be > 0, got {}",
            stats.deco_time_sec
        );
        // bottom_time should be the bottom_end_t value
        assert_eq!(stats.bottom_time_sec, stats.bottom_end_t);
    }
}
