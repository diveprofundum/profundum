# Formula Reference

Profundum includes a formula engine for user-defined calculated fields. Formulas are evaluated per-dive or per-segment and displayed alongside built-in stats.

## Syntax

### Literals
- Numbers: `12`, `3.5`, `0.21`
- Booleans: `true`, `false` (also via comparisons)

### Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `+` `-` `*` `/` | Arithmetic | `deco_time_min / bottom_time_min` |
| `>` `<` `>=` `<=` | Comparison | `max_depth_m >= 40` |
| `==` `!=` | Equality | `is_ccr == 1` |
| `and` `or` | Logical | `is_ccr and deco_required` |
| `not` | Logical negation | `not deco_required` |
| `-` (unary) | Negation | `-max_depth_m` |
| `? :` | Ternary conditional | `deco_required ? deco_time_min : 0` |
| `( )` | Grouping | `(total_time_min - bottom_time_min) / total_time_min` |

Operator precedence (highest to lowest): `* /`, `+ -`, `> < >= <=`, `== !=`, `and`, `or`.

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `min` | `min(a, b)` | Returns the smaller of two values |
| `max` | `max(a, b)` | Returns the larger of two values |
| `round` | `round(x, n)` | Rounds x to n decimal places |
| `abs` | `abs(x)` | Absolute value |
| `sqrt` | `sqrt(x)` | Square root |
| `floor` | `floor(x)` | Rounds down to nearest integer |
| `ceil` | `ceil(x)` | Rounds up to nearest integer |
| `if` | `if(cond, a, b)` | Returns a if cond is non-zero, otherwise b |

## Dive Variables

Variables available when a formula is evaluated in dive context. All values are numeric (booleans are 1.0 or 0.0).

### Depth

| Variable | Unit | Description |
|----------|------|-------------|
| `max_depth_m` | meters | Maximum depth reached |
| `avg_depth_m` | meters | Simple average depth across all samples |
| `weighted_avg_depth_m` | meters | Time-weighted average depth |
| `max_depth_ft` | feet | Maximum depth (imperial) |
| `avg_depth_ft` | feet | Average depth (imperial) |
| `weighted_avg_depth_ft` | feet | Time-weighted average depth (imperial) |

### Time

| Variable | Unit | Description |
|----------|------|-------------|
| `total_time_sec` | seconds | Total dive duration (start to end) |
| `total_time_min` | minutes | Total dive duration |
| `bottom_time_sec` | seconds | Time from start to bottom end (deco dives only, 0 for non-deco) |
| `bottom_time_min` | minutes | Bottom time |

### Three-Phase Boundaries

These variables describe the three phases of a deco dive: bottom phase, ascent/transit phase, and deco phase. All are 0 for non-deco dives.

| Variable | Unit | Description |
|----------|------|-------------|
| `bottom_end_t` | seconds | Time when diver leaves working depth (end of bottom phase). User-overridable. |
| `bottom_end_t_min` | minutes | Bottom end time |
| `deco_start_t` | seconds | Time when deco phase begins (OC: first gas switch after bottom end; CCR: arrival at first stop). User-overridable. |
| `ascent_time_sec` | seconds | Transit time from working depth to first deco stop (`deco_start_t - bottom_end_t`) |
| `ascent_time_min` | minutes | Ascent/transit time |

### Decompression

| Variable | Unit | Description |
|----------|------|-------------|
| `deco_time_sec` | seconds | All time from `deco_start_t` to end of dive. Once you leave working depth into your deco profile, everything until surfacing is deco time. |
| `deco_time_min` | minutes | Deco time |
| `deco_obligation_sec` | seconds | Total time with ceiling > 0 (including at depth). Distinct from `deco_time` — measures actual obligation, not phase duration. |
| `deco_obligation_min` | minutes | Deco obligation time |
| `deco_required` | boolean | 1 if dive had any deco obligation, 0 otherwise |
| `max_tts_sec` | seconds | Peak time-to-surface during the dive |
| `max_tts_min` | minutes | Peak TTS |
| `max_ceiling_m` | meters | Deepest deco ceiling encountered |
| `max_ceiling_ft` | feet | Deepest deco ceiling (imperial) |
| `max_gf99` | percent | Peak GF99 value during the dive |
| `gas_switch_count` | count | Number of gas switches during the dive |

### Temperature

| Variable | Unit | Description |
|----------|------|-------------|
| `min_temp_c` | Celsius | Minimum temperature |
| `max_temp_c` | Celsius | Maximum temperature |
| `avg_temp_c` | Celsius | Average temperature |
| `min_temp_f` | Fahrenheit | Minimum temperature (imperial) |
| `max_temp_f` | Fahrenheit | Maximum temperature (imperial) |
| `avg_temp_f` | Fahrenheit | Average temperature (imperial) |

### Rates

| Variable | Unit | Description |
|----------|------|-------------|
| `descent_rate_m_min` | m/min | Average descent rate (surface to max depth) |
| `ascent_rate_m_min` | m/min | Average ascent rate (max depth to surface) |

### CCR / Gas

| Variable | Unit | Description |
|----------|------|-------------|
| `is_ccr` | boolean | 1 if closed-circuit rebreather dive, 0 if open-circuit |
| `cns_percent` | percent | Central nervous system oxygen toxicity |
| `otu` | units | Oxygen toxicity units |
| `o2_consumed_psi` | PSI | O2 consumed (imperial, 0 if not available) |
| `o2_consumed_bar` | bar | O2 consumed (metric, 0 if not available) |
| `o2_rate_cuft_min` | cuft/min | O2 consumption rate (imperial, 0 if not available) |
| `o2_rate_l_min` | L/min | O2 consumption rate (metric, 0 if not available) |

## Segment Variables

Variables available when a formula is evaluated in segment context (a user-defined time range within a dive).

| Variable | Unit | Description |
|----------|------|-------------|
| `start_t_sec` | seconds | Segment start time (offset from dive start) |
| `end_t_sec` | seconds | Segment end time |
| `duration_sec` | seconds | Segment duration |
| `duration_min` | minutes | Segment duration |
| `max_depth_m` | meters | Maximum depth within segment |
| `avg_depth_m` | meters | Average depth within segment |
| `max_depth_ft` | feet | Maximum depth (imperial) |
| `avg_depth_ft` | feet | Average depth (imperial) |
| `min_temp_c` | Celsius | Minimum temperature in segment |
| `max_temp_c` | Celsius | Maximum temperature in segment |
| `min_temp_f` | Fahrenheit | Minimum temperature (imperial) |
| `max_temp_f` | Fahrenheit | Maximum temperature (imperial) |
| `deco_time_sec` | seconds | Overlap of deco phase with segment range |
| `deco_time_min` | minutes | Deco time within segment |
| `deco_obligation_sec` | seconds | Time with ceiling > 0 within segment |
| `deco_obligation_min` | minutes | Deco obligation within segment |
| `max_tts_sec` | seconds | Peak TTS within segment |
| `max_tts_min` | minutes | Peak TTS within segment |
| `sample_count` | count | Number of samples in segment |

## Examples

### Basic ratios
```
deco_time_min / bottom_time_min
```
Deco ratio: how much deco time per minute of bottom time.

### Conditional fields
```
deco_required ? deco_time_min : 0
```
Only show deco time for deco dives.

### Depth classification
```
max_depth_m >= 60 ? 3 : max_depth_m >= 40 ? 2 : max_depth_m >= 18 ? 1 : 0
```
Numeric depth tier (0 = rec, 1 = deep, 2 = extended, 3 = extreme).

### CCR O2 consumption
```
round(o2_consumed_bar / bottom_time_min, 2)
```
O2 burn rate in bar/min during bottom phase.

### OTU per minute
```
round(otu / total_time_min, 2)
```

### Deco efficiency
```
round(deco_obligation_min / deco_time_min * 100, 1)
```
What percentage of deco phase time had actual ceiling obligation (vs free ascent).

### CCR deco dives only
```
if(is_ccr and deco_required, deco_time_min, 0)
```

## Notes

- Division by zero returns an error (formula is not evaluated for that dive).
- Boolean variables (`is_ccr`, `deco_required`) are 1.0 or 0.0. Use in comparisons: `is_ccr == 1`.
- Variables not available for a dive (e.g., `o2_consumed_psi` when no O2 data) default to 0.
- Three-phase variables (`bottom_end_t`, `deco_start_t`, `ascent_time_sec`) are 0 for non-deco dives.
- Both `bottom_end_t` and `deco_start_t` can be manually overridden by the user, which affects all dependent computed values.
