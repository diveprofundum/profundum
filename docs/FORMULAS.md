# Formula Engine (Draft v1)

## Goals
- Let divers define reusable calculated fields across dives.
- Support CCR-focused metrics (deco ratio, CCR hours per unit, scrubber usage proxies).
- Keep syntax compact and spreadsheet-friendly.

## Expression grammar (v1)
- Numbers: `12`, `3.5`
- Variables: `max_depth_m`, `bottom_time_min`, `deco_time_min`, `otu`, `cns_percent`
- Arithmetic: `+ - * / ( )`
- Comparators: `> < >= <= == !=`
- Boolean: `and`, `or`, `not`
- Ternary: `cond ? a : b`
- Functions: `min(a,b)`, `max(a,b)`, `round(x, n)`

## Examples
- `deco_time_min / bottom_time_min`
- `max_depth_m >= 60 ? 1 : 0`
- `round(otu / bottom_time_min, 2)`
- `is_ccr and deco_time_min > 0 ? 1 : 0`

## Variable sets
### Dive-level
- `max_depth_m`, `avg_depth_m`, `weighted_avg_depth_m`
- `max_depth_ft`, `avg_depth_ft`, `weighted_avg_depth_ft`
- `bottom_time_sec`, `bottom_time_min`, `total_time_sec`, `total_time_min`
- `deco_time_sec`, `deco_time_min`
- `cns_percent`, `otu`, `is_ccr`, `deco_required`
- `min_temp_c`, `max_temp_c`, `avg_temp_c`
- `min_temp_f`, `max_temp_f`, `avg_temp_f`
- `gas_switch_count`, `max_ceiling_m`, `max_ceiling_ft`, `max_gf99`
- `descent_rate_m_min`, `ascent_rate_m_min`
- `o2_consumed_psi`, `o2_consumed_bar`, `o2_rate_cuft_min`, `o2_rate_l_min`

### Segment-level (if context is a segment)
- `start_t_sec`, `end_t_sec`, `duration_sec`, `duration_min`
- `max_depth_m`, `avg_depth_m`
- `max_depth_ft`, `avg_depth_ft`
- `min_temp_c`, `max_temp_c`
- `min_temp_f`, `max_temp_f`
- `deco_time_sec`, `deco_time_min`, `sample_count`

## Workflow
1. Create a formula from the Formula Library.
2. Choose scope: Dive or Segment.
3. Validate and preview on a sample dive.
4. Save and apply to all dives (or a filtered subset).
5. Use calculated fields in list columns, filters, and summaries.

## Validation rules
- Unknown variables rejected with a clear error.
- Division by zero returns `null` and logs a warning.
- All formulas are versioned and stored with original expression.

## CCR O2 examples
- Imperial rate: `(o2_consumed_psi * o2_tank_factor) / bottom_time_min`
- Metric rate: `o2_consumed_bar * o2_tank_factor / bottom_time_min`
