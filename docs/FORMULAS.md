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
- `max_depth_m`
- `avg_depth_m`
- `bottom_time_min`
- `deco_time_min`
- `otu`
- `cns_percent`
- `is_ccr`
- `gas_switch_count`
- `setpoint_change_count`
- `o2_consumed_psi`
- `o2_consumed_bar`
- `o2_rate_cuft_min`
- `o2_rate_l_min`
- `o2_tank_factor`

### Segment-level (if context is a segment)
- `segment_time_min`
- `segment_avg_depth_m`
- `segment_deco_time_min`
- `segment_otu`
- `segment_cns_percent`

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
