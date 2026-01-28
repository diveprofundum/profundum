# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Development Commands

### Rust Core (primary development target)
```bash
# Build the core library
cd core && cargo build

# Run tests
cd core && cargo test

# Run a single test
cd core && cargo test test_name

# Lint and format (required before commits)
cd core && cargo fmt --check
cd core && cargo clippy --all-targets --all-features -- -D warnings

# Generate UniFFI bindings (happens automatically during build)
cd core && cargo build
```

### CI Pipeline
The project uses GitLab CI with stages: lint → test → ui → perf. See `.gitlab-ci.yml`.

## Architecture

### Core Design: Rust + UniFFI + Native UIs

```
┌─────────────────────────────────────────────────────┐
│  Native UI                                          │
│  ├── Apple: SwiftUI (apps/macos/, apps/ios/)        │
│  └── Others: Compose Multiplatform                  │
│      (apps/android/, apps/desktop/, apps/compose/)  │
├─────────────────────────────────────────────────────┤
│  Platform BLE Adapters                              │
│  (CoreBluetooth, WinRT BLE, BlueZ, Kotlin BLE)      │
├─────────────────────────────────────────────────────┤
│  Rust Core (core/)                                  │
│  Exposed to Swift/Kotlin via UniFFI                 │
└─────────────────────────────────────────────────────┘
```

### Core Module Structure (core/src/)

- **lib.rs**: FFI entry point, re-exports public API via `uniffi::include_scaffolding!`
- **models.rs**: Domain types (Dive, Device, Site, Buddy, Equipment, Segment, Formula, DiveSample)
- **storage.rs**: `Storage` trait defining CRUD + query interface; `DiveQuery` for filtered dive lists
- **ble.rs**: `BleAdapter` trait for platform BLE implementations; error taxonomy (`BleError`)
- **ble_mock.rs**: `MockBleAdapter` for testing without hardware
- **migrations.rs**: SQLite schema versioning via `core/migrations/*.sql` files
- **divelog.udl**: UniFFI interface definition for FFI binding generation

### Key Abstractions

**BleAdapter trait** (`ble.rs`): Platform-agnostic interface for BLE operations (scan, connect, download logs). Each platform implements this trait using native BLE APIs.

**Storage trait** (`storage.rs`): Database interface supporting devices, dives, samples, segments, sites, buddies, equipment, formulas, and calculated fields. Implementation should use SQLite.

**DiveQuery** (`storage.rs`): Filter struct for dive list queries (time range, depth, CCR flag, tags).

### Data Model Highlights

The schema (`core/schema.sql`) models technical diving with CCR support:
- Dives track CNS/OTU, setpoint, O2 consumption rates, deco status
- Samples include depth, temp, setpoint_ppo2, ceiling_m, gf99
- Segments are first-class entities for analyzing portions of a dive
- Formulas enable user-defined calculated fields (e.g., `deco_time_min / bottom_time_min`)

### FFI Boundary

UniFFI generates Swift and Kotlin bindings from `core/src/divelog.udl`. The build process:
1. `build.rs` invokes `uniffi::generate_scaffolding("src/divelog.udl")`
2. Produces native bindings at compile time
3. Swift: linked into Xcode projects
4. Kotlin: packaged as AAR (Android) or JVM dependency (desktop)

## Key Constraints

- **Local-first**: No network calls without explicit user action
- **Privacy-first**: All data stored locally; cloud sync is future opt-in feature
- **Schema migrations**: Never modify existing migrations; add new numbered files to `core/migrations/`
- **Permissive licensing**: Prefer MIT/Apache-2.0 dependencies; avoid copyleft in core

## Project Phase

Currently in **Phase 0 (scaffolding)**. The Storage trait is defined but not implemented. Frontend apps are placeholders. See `docs/ROADMAP.md` for phases.
