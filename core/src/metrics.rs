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
    /// Deco time in seconds (ascent-phase only: ceiling > 0 after leaving working depth)
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

        // bottom_end_t: last sample within 1m of max depth (end of working depth phase)
        let bottom_end_t: i32 = if has_deco && max_depth_m > 0.0 {
            let threshold = (max_depth_m - 1.0).max(0.0);
            samples
                .iter()
                .rposition(|s| s.depth_m >= threshold)
                .map_or(0, |idx| samples[idx].t_sec)
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

        // Deco tracking (split into ascent-phase and total obligation)
        let mut deco_time_sec: i32 = 0;
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

            // Deco time: split into total obligation and ascent-phase only
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
                    if sample.t_sec > bottom_end_t {
                        deco_time_sec += deco_dt;
                    }
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
    /// `dive_bottom_end_t` is the dive-level bottom-end time (last sample within
    /// 1m of max depth). Samples with `t_sec > dive_bottom_end_t` and `ceiling > 0`
    /// count as ascent-phase deco (`deco_time_sec`); all ceiling > 0 samples count
    /// toward `deco_obligation_sec`.
    pub fn compute(
        start_t_sec: i32,
        end_t_sec: i32,
        all_samples: &[SampleInput],
        dive_bottom_end_t: i32,
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
        let mut deco_time_sec: i32 = 0;
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
                    if sample.t_sec > dive_bottom_end_t {
                        deco_time_sec += dt;
                    }
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
        assert!(stats.deco_time_sec > 0);
        assert_eq!(stats.max_ceiling_m, 6.0);
        assert_eq!(stats.max_gf99, 80.0);
        assert_eq!(stats.gas_switch_count, 0); // all gasmix_index are None
        assert_eq!(stats.depth_class, DepthClass::Deep);
        // Descent: 30m over 5 min (first max at t=300) = 6.0 m/min
        assert!((stats.descent_rate_m_min - 6.0).abs() < 0.01);
        // Ascent: 30m over 15 min (last max at t=600, end at t=1500) = 2.0 m/min
        assert!((stats.ascent_rate_m_min - 2.0).abs() < 0.01);
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

        let stats = SegmentStats::compute(300, 600, &samples, 0);

        assert_eq!(stats.duration_sec, 300);
        assert_eq!(stats.max_depth_m, 30.0);
        assert_eq!(stats.min_temp_c, 16.0);
        assert!(stats.deco_time_sec > 0);
        assert_eq!(stats.sample_count, 2);
    }

    #[test]
    fn test_segment_stats_empty() {
        let stats = SegmentStats::compute(5000, 6000, &[], 0);

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

        // bottom_time (deco dive): last sample at max depth 30m is at t=600
        assert_eq!(stats.bottom_time_sec, 600);

        // deco_obligation (all ceiling > 0): samples 3,4,5 with dt=[300,300,300] = 900
        assert_eq!(stats.deco_obligation_sec, 900);
        // deco_time (ascent-phase only, t > bottom_end_t=600): sample 5 dt=300
        assert_eq!(stats.deco_time_sec, 300);

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
        let stats = SegmentStats::compute(300, 900, &samples, 0);

        assert_eq!(stats.duration_sec, 600);
        assert_eq!(stats.max_depth_m, 30.0);
        // avg_depth = (30+30+20)/3
        let expected_avg = (30.0 + 30.0 + 20.0) / 3.0;
        assert!((stats.avg_depth_m - expected_avg as f32).abs() < 1e-6);
        assert_eq!(stats.min_temp_c, 16.0);
        assert_eq!(stats.max_temp_c, 17.0);
        assert_eq!(stats.sample_count, 3);
        // deco: all 3 samples have ceiling > 0. dt=[300,300,300] = 900
        // With dive_bottom_end_t=0, all are in ascent phase
        assert_eq!(stats.deco_time_sec, 900);
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
        let stats = SegmentStats::compute(0, 60, &samples, 0);
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
        let stats = SegmentStats::compute(100, 200, &samples, 0);
        assert_eq!(stats.duration_sec, 100);
        assert_eq!(stats.max_depth_m, 15.0);
        assert_eq!(stats.avg_depth_m, 15.0);
        assert_eq!(stats.min_temp_c, 18.0);
        assert_eq!(stats.max_temp_c, 18.0);
        assert_eq!(stats.sample_count, 1);
        // single sample with ceiling > 0: dt fallback = 1
        assert_eq!(stats.deco_time_sec, 1);
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
        let stats = SegmentStats::compute(100, 500, &[], 0);
        assert_eq!(stats.duration_sec, 400);
    }

    #[test]
    fn test_dive_stats_single_sample_fallbacks() {
        // Single sample exercises dt=1 fallback for weighted avg and bottom time
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 60,
            bottom_time_sec: 0,
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
        // sample 1 (i=1): ceiling=3>0, dt=300; t=100 <= bottom_end_t=100 → obligation only
        // sample 2 (i=2): ceiling=2>0, dt=300; t=400 > bottom_end_t=100 → both
        assert_eq!(stats.deco_obligation_sec, 600);
        assert_eq!(stats.deco_time_sec, 300);
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
        let stats = SegmentStats::compute(100, 400, &samples, 0);
        // sample 0 (i=0): ceiling=3>0, dt=300; sample 1 (i=1): ceiling=2>0, dt=300
        // dive_bottom_end_t=0, all t>0 → both are ascent-phase
        assert_eq!(stats.deco_time_sec, 600);
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
        let stats = SegmentStats::compute(0, 60, &samples, 0);
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
        // Last sample at ≥ 39m (max 40 - 1) is at t=1200
        assert_eq!(stats.bottom_time_sec, 1200);
        // deco_obligation: all ceiling>0 (t=900,1200,1500,1800) dt=[300,300,300,600] = 1500
        assert_eq!(stats.deco_obligation_sec, 1500);
        // deco_time: only t>1200 (t=1500,1800) dt=[300,600] = 900
        assert_eq!(stats.deco_time_sec, 900);
    }

    #[test]
    fn test_bottom_time_multi_level_deco() {
        // Multi-level: 30m → 25m → back to 30m → ascent to deco stops
        // Bottom time = last time at ≥ 29m
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 3000,
            bottom_time_sec: 0,
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
        // Last sample at ≥ 29m is the return at t=600
        assert_eq!(stats.bottom_time_sec, 600);
    }

    #[test]
    fn test_bottom_time_depth_oscillation_within_threshold() {
        // Diver at 29.5-30m (both within 1m of max=30) — bottom time includes full phase
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 2000,
            bottom_time_sec: 0,
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
        // max=30, threshold=29. All bottom samples (30, 29.5, 29.2) are >= 29.
        // Last at ≥ 29m is at t=600.
        assert_eq!(stats.bottom_time_sec, 600);
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

        // max_depth=50, threshold=49. Last sample at >=49m is t=1200
        assert_eq!(stats.bottom_time_sec, 1200);
        assert_eq!(stats.max_tts_sec, 600);

        // deco_obligation: ceiling > 0 at t=600,1200,1500,1800,2400
        // dt: 600,300,300,600,300 = 2100
        assert_eq!(stats.deco_obligation_sec, 2100);

        // deco_time: only t > 1200: t=1500,1800,2400
        // dt: 300,600,300 = 1200
        assert_eq!(stats.deco_time_sec, 1200);
    }

    #[test]
    fn test_tts_tracking() {
        // Verify max_tts_sec is correctly tracked
        let dive = DiveInput {
            start_time_unix: 0,
            end_time_unix: 1200,
            bottom_time_sec: 0,
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

        // dive_bottom_end_t=600 (last sample at working depth)
        let stats = SegmentStats::compute(300, 900, &samples, 600);

        // deco_obligation: all 3 samples have ceiling>0, dt=[300,300,300]=900
        assert_eq!(stats.deco_obligation_sec, 900);
        // deco_time: only t>600 (t=900), dt=300
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
}
