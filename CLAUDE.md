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

### Makefile (root)
```bash
make test              # Run Rust + Swift tests (xcframework rebuilt automatically)
make lint              # cargo fmt --check + clippy
make xcframework       # Build DivelogCompute XCFramework
make swift-bindings    # Regenerate UniFFI Swift bindings
make version-check     # Verify VERSION, Cargo.toml, Xcode project are in sync
make version-sync V=0.2.0  # Set new version and sync to all manifests
make verify            # Check XCFramework integrity
make coverage          # Generate lcov coverage reports (Rust + Swift)
make coverage-report   # Generate HTML coverage reports
make clean             # Clean all build artifacts
make help              # Show all available targets
```

### CI Pipeline
GitHub Actions (`.github/workflows/ci.yml`) with path-filtered jobs:
- **`rust-lint`** / **`rust-test`** — triggered by changes to `core/**`
- **`swift-test`** — triggered by changes to `core/**`, `apple/**`, or `Profundum/**` (runs on macOS, rebuilds xcframework)
- **`coverage`** — collects Rust + Swift coverage, uploads to Codecov (95% project / 90% patch thresholds)
- **`version-check`** — ensures VERSION file matches all manifests

### Versioning
Single version for the entire monorepo. Source of truth: `VERSION` file at root.
- `make version-sync V=X.Y.Z` updates VERSION, Cargo.toml, and Xcode MARKETING_VERSION
- `make version-check` verifies consistency (also runs in CI)

## Architecture

### Hybrid Architecture: Native-First with Rust Compute Core

```
┌─────────────────────────────────────────────────────────────┐
│  Swift Layer (Native)                                       │
│  ├── SwiftUI Views (Profundum/ multiplatform app)            │
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

- **Sources/Models/**: GRDB Record types (Device, Dive, DiveSample, DiveWithSite, DiveSourceFingerprint, GasMix, Site, Teammate, Equipment, Segment, Formula, Settings, PredefinedDiveTag)
- **Sources/Database/**:
  - `DivelogDatabase.swift`: GRDB DatabaseQueue wrapper with migrations
  - `DiveQuery.swift`: Type-safe query builder for dive filtering/pagination
- **Sources/Services/**:
  - `DiveService.swift`: Main CRUD operations for all entity types
  - `FormulaService.swift`: Formula validation, evaluation, and computed stats
  - `ExportService.swift`: JSON export/import functionality
  - `ShearwaterCloudImportService.swift`: Shearwater Cloud .db import with multi-computer merge
  - `DiveComputerImportService.swift`: BLE dive computer import via libdivecomputer
  - `DiveDataMapper.swift`: Pure mapping from libdivecomputer parsed data to domain models
  - `DiveDownloadService.swift`: Protocol + factory for runtime dive download capability
- **Sources/DiveComputer/**:
  - `BLETransport.swift`: Protocol abstracting CoreBluetooth for testability
  - `IOStreamBridge.swift`: Bridges BLETransport → libdivecomputer dc_custom_cbs_t
  - `DCDescriptorList.swift`: Device descriptor matching via dc_descriptor_filter
  - `KnownDevices.swift`: Static list of known dive computer BLE names
- **Sources/RustBridge/**:
  - `DivelogCompute.swift`: Swift namespace wrapping UniFFI-generated free functions
  - `Generated/divelog_compute.swift`: UniFFI-generated Swift bindings (types + FFI calls)
  - `Generated/divelog_computeFFI.h`: C header for the FFI interface

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

The schema (implemented in Swift GRDB migrations 001–009) models technical diving with CCR support:
- Dives track CNS/OTU, setpoint, O2 consumption rates, deco status
- Dive tags include breathing-system tags (oc, ccr) and activity tags (rec, deco, cave, etc.) plus user custom tags
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
- `max_depth_ft`, `avg_depth_ft`, `weighted_avg_depth_ft` (imperial equivalents)
- `bottom_time_sec`, `bottom_time_min`, `total_time_sec`, `total_time_min`
- `deco_time_sec`, `deco_time_min`
- `cns_percent`, `otu`, `is_ccr`, `deco_required`
- `min_temp_c`, `max_temp_c`, `avg_temp_c`
- `min_temp_f`, `max_temp_f`, `avg_temp_f` (imperial equivalents)
- `gas_switch_count`, `max_ceiling_m`, `max_ceiling_ft`, `max_gf99`
- `descent_rate_m_min`, `ascent_rate_m_min`
- `o2_consumed_psi`, `o2_consumed_bar`, `o2_rate_cuft_min`, `o2_rate_l_min`

Variables available for segment formulas:
- `start_t_sec`, `end_t_sec`, `duration_sec`, `duration_min`
- `max_depth_m`, `avg_depth_m`
- `max_depth_ft`, `avg_depth_ft` (imperial equivalents)
- `min_temp_c`, `max_temp_c`
- `min_temp_f`, `max_temp_f` (imperial equivalents)
- `deco_time_sec`, `deco_time_min`, `sample_count`

## Key Constraints

- **Local-first**: No network calls without explicit user action
- **Privacy-first**: All data stored locally; cloud sync is future opt-in feature
- **Stateless Rust**: Rust compute core has no state, no storage dependencies
- **Swift-owned storage**: All CRUD operations and schema migrations are in Swift/GRDB
- **Permissive licensing**: Prefer MIT/Apache-2.0 dependencies; avoid copyleft in core

## Testing Standards

- **New logic/services** must have unit tests
- **Bug fixes** should include a regression test
- **View-layer wiring** covered by manual QA checklist (until UI test infra exists)

### Coverage
- Local: `make coverage` (lcov in `coverage/`) or `make coverage-report` (HTML)
- CI: Codecov on every PR with diff comments (blocking)
- Thresholds: 95% project (both Rust and Swift), 90% patch (new code)
- Install locally: `cargo install cargo-llvm-cov`

### Validation Suite (required for all code changes)

**Before opening a PR**, run the full validation suite locally:

| Step | Command | Notes |
|------|---------|-------|
| 1. Lint | `make lint` | Rust fmt + clippy, SwiftLint strict |
| 2. Tests | `make test` | Rust + Swift test suites |
| 3. Build | `xcodebuild build -project Profundum/Profundum.xcodeproj -scheme Profundum -destination 'platform=macOS' -quiet` | macOS build |
| 4. Security | `make security` | cargo audit + cargo deny |
| 5. Mutation testing | `make mutants` | Rust compute core (slow, local only) |
| 6. Version check | `make version-check` | Only if manifests changed |

**After opening the PR**, run code reviews:

| Step | Action | Notes |
|------|--------|-------|
| 7. Self-review | Run `/review-pr` skill | Structured review against project checklist |
| 8. Second-opinion review | Send diff to Codex MCP | Independent review for bugs, edge cases, improvements |

All 8 steps are mandatory. Do not skip any step.

## Project Phase

**Completed:**
- ✅ Phase 1: Hybrid architecture — Rust compute core, Swift GRDB storage, models, services
- ✅ Phase 2: Performance & batch APIs — batch operations, calculated fields, DiveStats
- ✅ Phase 3: Dive computer import — Shearwater Cloud import, libdivecomputer binary parsing, multi-computer merge
- ✅ Phase 4: Multiplatform SwiftUI app (Profundum/) — iOS + macOS with shared views
- ✅ Phase 5: Swift Charts migration — DepthProfileChart & PPO2Chart using `import Charts` with interactive scrub
- ✅ Phase 6: Accessibility pass — VoiceOver support for StatCard, charts, filter chips, dive rows, badges, GPS
- ✅ Phase 7: UniFFI build automation — root Makefile, verify-xcframework.sh, docs/uniffi-build.md
- ✅ Phase 8: Test coverage expansion — 37 Shearwater import tests (error handling, edge cases, stress, merge)

**In progress / next:**
- ⏳ GitHub repo setup (CI workflow written, needs repo creation + first push)
- ⏳ UI features: dive editing polish, export/share UI, formula management UI
- ⏳ Multi-platform: Android/Kotlin, Web/TypeScript, Windows/Desktop (scaffolded in `apps/`)

## Directory Structure

```
divelog/
├── Makefile                  # Root build automation (xcframework, test, clean)
├── core/                     # Rust compute core
│   ├── Cargo.toml
│   ├── build.rs
│   ├── build-xcframework.sh  # XCFramework build script
│   └── src/
│       ├── lib.rs            # FFI entry point
│       ├── error.rs          # FormulaError
│       ├── metrics.rs        # DiveStats, SegmentStats
│       ├── divelog_compute.udl
│       └── formula/          # Parser and evaluator
├── apple/
│   └── DivelogCore/          # Swift Package
│       ├── Package.swift
│       ├── Sources/
│       │   ├── Models/       # GRDB Record types
│       │   ├── Database/     # DivelogDatabase, DiveQuery
│       │   ├── Services/     # DiveService, ShearwaterCloudImportService, etc.
│       │   ├── DiveComputer/ # BLETransport, IOStreamBridge, DCDescriptorList
│       │   └── RustBridge/   # DivelogCompute interface + Generated/
│       └── Tests/            # XCTest suites (DivelogCoreTests, ShearwaterCloudImportTests, etc.)
├── Profundum/                # Multiplatform SwiftUI app (iOS + macOS)
│   └── Profundum/
│       ├── ProfundumApp.swift
│       ├── Views/            # All SwiftUI views (Swift Charts, accessibility)
│       ├── BLE/              # CoreBluetooth integration
│       └── Helpers/          # App utilities
├── libdivecomputer/          # libdivecomputer submodule + XCFramework build
├── scripts/
│   └── verify-xcframework.sh # XCFramework integrity checker
├── docs/                     # Architecture, design, build docs
│   └── uniffi-build.md       # UniFFI pipeline documentation
└── schema/
    └── schema.sql           # Reference schema (implemented in Swift)
```
