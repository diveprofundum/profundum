# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Development Commands

### Rust Compute Core
```bash
# Build the compute library
cd core && cargo build

# Run tests
cd core && cargo test

# Run a single test
cd core && cargo test test_name

# Lint and format (required before commits)
cd core && cargo fmt --check
cd core && cargo clippy --all-targets --all-features -- -D warnings
```

### Swift Package (Apple platforms)
```bash
# Build the Swift package
cd apple/DivelogCore && swift build

# Run tests (requires Xcode)
cd apple/DivelogCore && swift test
```

### CI Pipeline
The project uses GitLab CI with stages: lint → test → ui → perf. See `.gitlab-ci.yml`.

## Architecture

### Hybrid Architecture: Native-First with Rust Compute Core

```
┌─────────────────────────────────────────────────────────────┐
│  Swift Layer (Native)                                       │
│  ├── SwiftUI Views (apps/macos/, apps/ios/)                 │
│  ├── GRDB Storage (all CRUD, queries, migrations)           │
│  ├── Native Models (Codable, FetchableRecord)               │
│  └── CoreBluetooth (platform BLE)                           │
├─────────────────────────────────────────────────────────────┤
│  Rust Compute Core (~500 lines, stateless)                  │
│  ├── Formula parser (nom-based)                             │
│  ├── Formula evaluator                                      │
│  └── Metrics computation (DiveStats, SegmentStats)          │
└─────────────────────────────────────────────────────────────┘
```

### Rust Compute Core (core/src/)

The Rust layer is a minimal, stateless compute library:

- **lib.rs**: FFI entry point, re-exports public API via `uniffi::include_scaffolding!`
- **error.rs**: `FormulaError` type for formula-related errors
- **metrics.rs**: `DiveStats` and `SegmentStats` computation from pure input types
- **formula/**: Formula parsing and evaluation engine
  - **ast.rs**: Abstract syntax tree types
  - **parser.rs**: nom-based expression parser
  - **evaluator.rs**: Expression evaluation with function support
  - **mod.rs**: Public API (`validate`, `compute`, `validate_with_variables`)

### Swift Storage Layer (apple/DivelogCore/)

Swift owns all storage, domain models, and CRUD operations:

- **Sources/Models/**: GRDB Record types (Device, Dive, DiveSample, Site, Buddy, Equipment, Segment, Formula, Settings)
- **Sources/Database/**:
  - `DivelogDatabase.swift`: GRDB DatabaseQueue wrapper with migrations
  - `DiveQuery.swift`: Type-safe query builder for dive filtering/pagination
- **Sources/Services/**:
  - `DiveService.swift`: Main CRUD operations for all entity types
  - `FormulaService.swift`: Formula validation, evaluation, and computed stats
  - `ExportService.swift`: JSON export/import functionality
- **Sources/RustBridge/**:
  - `DivelogCompute.swift`: Swift interface to Rust compute (placeholder, awaiting UniFFI integration)

### FFI Boundary

UniFFI generates Swift bindings from `core/src/divelog_compute.udl`. The interface is minimal (~5 functions):

```
namespace divelog_compute {
    string? validate_formula(string expression);
    string? validate_formula_with_variables(string expression, sequence<string> available);
    f64 evaluate_formula(string expression, record<string, f64> variables);
    DiveStats compute_dive_stats(DiveInput dive, sequence<SampleInput> samples);
    SegmentStats compute_segment_stats(i32 start_t_sec, i32 end_t_sec, sequence<SampleInput> samples);
    sequence<FunctionInfo> supported_functions();
}
```

### Data Model

The schema (implemented in Swift GRDB migrations) models technical diving with CCR support:
- Dives track CNS/OTU, setpoint, O2 consumption rates, deco status
- Samples include depth, temp, setpoint_ppo2, ceiling_m, gf99
- Segments are first-class entities for analyzing portions of a dive
- Formulas enable user-defined calculated fields (e.g., `deco_time_min / bottom_time_min`)

Key indices for performance:
- `idx_dives_start_time` - primary query: list dives by date
- `idx_samples_dive` - sample lookup for metrics
- `idx_dives_depth`, `idx_dives_ccr`, `idx_dives_deco` - filtering
- `idx_dive_tags_tag` - tag filtering

### Formula Variables

Variables available for dive formulas:
- `max_depth_m`, `avg_depth_m`, `weighted_avg_depth_m`
- `bottom_time_sec`, `bottom_time_min`, `total_time_sec`, `total_time_min`
- `deco_time_sec`, `deco_time_min`
- `cns_percent`, `otu`, `is_ccr`, `deco_required`
- `min_temp_c`, `max_temp_c`, `avg_temp_c`
- `gas_switch_count`, `max_ceiling_m`, `max_gf99`
- `descent_rate_m_min`, `ascent_rate_m_min`
- `o2_consumed_psi`, `o2_consumed_bar`, `o2_rate_cuft_min`, `o2_rate_l_min`

Variables available for segment formulas:
- `start_t_sec`, `end_t_sec`, `duration_sec`, `duration_min`
- `max_depth_m`, `avg_depth_m`
- `min_temp_c`, `max_temp_c`
- `deco_time_sec`, `deco_time_min`, `sample_count`

## Key Constraints

- **Local-first**: No network calls without explicit user action
- **Privacy-first**: All data stored locally; cloud sync is future opt-in feature
- **Stateless Rust**: Rust compute core has no state, no storage dependencies
- **Swift-owned storage**: All CRUD operations and schema migrations are in Swift/GRDB
- **Permissive licensing**: Prefer MIT/Apache-2.0 dependencies; avoid copyleft in core

## Project Phase

Currently in **Phase 1 (hybrid architecture)**:
- ✅ Rust compute core (formula parsing, metrics computation)
- ✅ Swift GRDB storage layer (models, migrations, services)
- ✅ Swift compute bridge (placeholder, ready for UniFFI integration)
- ⏳ UniFFI binding generation and XCFramework packaging
- ⏳ SwiftUI app implementation

## Directory Structure

```
divelog/
├── core/                     # Rust compute core
│   ├── Cargo.toml
│   ├── build.rs
│   └── src/
│       ├── lib.rs            # FFI entry point
│       ├── error.rs          # FormulaError
│       ├── metrics.rs        # DiveStats, SegmentStats
│       ├── divelog_compute.udl
│       └── formula/          # Parser and evaluator
├── apple/
│   └── DivelogCore/          # Swift Package
│       ├── Package.swift
│       └── Sources/
│           ├── Models/       # GRDB Record types
│           ├── Database/     # DivelogDatabase, DiveQuery
│           ├── Services/     # DiveService, FormulaService, ExportService
│           └── RustBridge/   # DivelogCompute interface
├── apps/
│   ├── macos/               # macOS SwiftUI (placeholder)
│   └── ios/                 # iOS SwiftUI (placeholder)
└── schema/
    └── schema.sql           # Reference schema (implemented in Swift)
```
