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
    /// Bottom time in seconds (time at depth > 3m)
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
}

/// Computed statistics for a dive.
#[derive(Debug, Clone)]
pub struct DiveStats {
    /// Total dive time in seconds
    pub total_time_sec: i32,
    /// Bottom time in seconds (time at depth > 3m)
    pub bottom_time_sec: i32,
    /// Deco time in seconds (time with ceiling > 0)
    pub deco_time_sec: i32,
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

        // Calculate depths and temperatures
        let mut max_depth_m: f32 = 0.0;
        let mut depth_sum: f64 = 0.0;
        let mut weighted_depth_sum: f64 = 0.0;
        let mut weight_sum: f64 = 0.0;
        let mut min_temp_c = f32::MAX;
        let mut max_temp_c = f32::MIN;
        let mut temp_sum: f64 = 0.0;

        // Deco and ceiling tracking
        let mut deco_time_sec: i32 = 0;
        let mut max_ceiling_m: f32 = 0.0;
        let mut max_gf99: f32 = 0.0;

        // Gas switch detection
        let mut gas_switch_count: u32 = 0;
        let mut prev_setpoint: Option<f32> = None;

        // Bottom time (depth > 3m)
        let mut bottom_time_sec: i32 = 0;

        for (i, sample) in samples.iter().enumerate() {
            // Depth stats
            if sample.depth_m > max_depth_m {
                max_depth_m = sample.depth_m;
            }
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

            // Deco time: when ceiling > 0
            if let Some(ceiling) = sample.ceiling_m {
                if ceiling > 0.0 {
                    let deco_dt = if i + 1 < samples.len() {
                        samples[i + 1].t_sec - sample.t_sec
                    } else if i > 0 {
                        sample.t_sec - samples[i - 1].t_sec
                    } else {
                        1
                    };
                    deco_time_sec += deco_dt;
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

            // Gas switch detection
            if let Some(setpoint) = sample.setpoint_ppo2 {
                if let Some(prev) = prev_setpoint {
                    if (setpoint - prev).abs() > 0.05 {
                        gas_switch_count += 1;
                    }
                }
                prev_setpoint = Some(setpoint);
            }

            // Bottom time (below 3m threshold)
            if sample.depth_m > 3.0 {
                let bt_dt = if i + 1 < samples.len() {
                    samples[i + 1].t_sec - sample.t_sec
                } else if i > 0 {
                    sample.t_sec - samples[i - 1].t_sec
                } else {
                    1
                };
                bottom_time_sec += bt_dt;
            }
        }

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

    fn compute_rates(samples: &[SampleInput]) -> (f32, f32) {
        if samples.len() < 2 {
            return (0.0, 0.0);
        }

        // Find max depth index
        let max_idx = samples
            .iter()
            .enumerate()
            .max_by(|(_, a), (_, b)| a.depth_m.partial_cmp(&b.depth_m).unwrap())
            .map(|(i, _)| i)
            .unwrap_or(0);

        // Descent rate: from start to max depth
        let descent_rate = if max_idx > 0 {
            let dt_min = (samples[max_idx].t_sec - samples[0].t_sec) as f32 / 60.0;
            if dt_min > 0.0 {
                samples[max_idx].depth_m / dt_min
            } else {
                0.0
            }
        } else {
            0.0
        };

        // Ascent rate: from max depth to end
        let ascent_rate = if max_idx < samples.len() - 1 {
            let last = samples.last().unwrap();
            let dt_min = (last.t_sec - samples[max_idx].t_sec) as f32 / 60.0;
            if dt_min > 0.0 {
                (samples[max_idx].depth_m - last.depth_m) / dt_min
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
    /// Deco time within segment
    pub deco_time_sec: i32,
    /// Number of samples in segment
    pub sample_count: u64,
}

impl SegmentStats {
    /// Compute statistics for a segment from samples within its time range.
    pub fn compute(start_t_sec: i32, end_t_sec: i32, all_samples: &[SampleInput]) -> Self {
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
                sample_count: 0,
            };
        }

        let mut max_depth_m: f32 = 0.0;
        let mut depth_sum: f64 = 0.0;
        let mut min_temp_c = f32::MAX;
        let mut max_temp_c = f32::MIN;
        let mut deco_time_sec: i32 = 0;

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
                    deco_time_sec += dt;
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
            },
            SampleInput {
                t_sec: 60,
                depth_m: 10.0,
                temp_c: 20.0,
                setpoint_ppo2: Some(1.0),
                ceiling_m: Some(0.0),
                gf99: Some(20.0),
            },
            SampleInput {
                t_sec: 120,
                depth_m: 20.0,
                temp_c: 18.0,
                setpoint_ppo2: Some(1.3),
                ceiling_m: Some(0.0),
                gf99: Some(40.0),
            },
            SampleInput {
                t_sec: 300,
                depth_m: 30.0,
                temp_c: 16.0,
                setpoint_ppo2: Some(1.3),
                ceiling_m: Some(3.0),
                gf99: Some(60.0),
            },
            SampleInput {
                t_sec: 600,
                depth_m: 30.0,
                temp_c: 16.0,
                setpoint_ppo2: Some(1.3),
                ceiling_m: Some(6.0),
                gf99: Some(80.0),
            },
            SampleInput {
                t_sec: 900,
                depth_m: 20.0,
                temp_c: 17.0,
                setpoint_ppo2: Some(1.0),
                ceiling_m: Some(3.0),
                gf99: Some(70.0),
            },
            SampleInput {
                t_sec: 1200,
                depth_m: 5.0,
                temp_c: 19.0,
                setpoint_ppo2: Some(1.0),
                ceiling_m: Some(0.0),
                gf99: Some(50.0),
            },
            SampleInput {
                t_sec: 1500,
                depth_m: 0.0,
                temp_c: 21.0,
                setpoint_ppo2: Some(1.0),
                ceiling_m: Some(0.0),
                gf99: Some(30.0),
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
        assert_eq!(stats.gas_switch_count, 2); // 1.0 -> 1.3 -> 1.0
        assert_eq!(stats.depth_class, DepthClass::Deep);
        assert!(stats.descent_rate_m_min > 0.0);
        assert!(stats.ascent_rate_m_min > 0.0);
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

        let stats = SegmentStats::compute(300, 600, &samples);

        assert_eq!(stats.duration_sec, 300);
        assert_eq!(stats.max_depth_m, 30.0);
        assert_eq!(stats.min_temp_c, 16.0);
        assert!(stats.deco_time_sec > 0);
        assert_eq!(stats.sample_count, 2);
    }

    #[test]
    fn test_segment_stats_empty() {
        let stats = SegmentStats::compute(5000, 6000, &[]);

        assert_eq!(stats.duration_sec, 1000);
        assert_eq!(stats.sample_count, 0);
        assert_eq!(stats.max_depth_m, 0.0);
    }
}
