# Architecture

## Overview

Profundum is a hybrid Swift + Rust dive logging application for iOS and macOS.

- **Swift** owns all storage (GRDB/SQLite), UI (SwiftUI), and platform integrations (CoreBluetooth).
- **Rust** provides a stateless compute core for formula parsing and dive metrics.
- **libdivecomputer** (C) handles dive computer protocol parsing over BLE.

## Layer diagram

```
┌─────────────────────────────────────────────────────────┐
│  Profundum (SwiftUI multiplatform app — iOS + macOS)    │
│  ├── Views: dive list, detail, charts, settings, sync   │
│  ├── BLE: scanner, peripheral transport, import session │
│  └── Helpers: date formatters, unit formatter            │
├─────────────────────────────────────────────────────────┤
│  DivelogCore (Swift package)                            │
│  ├── Models: Dive, DiveSample, Device, Site, GasMix…    │
│  ├── Database: GRDB migrations, DiveQuery builder       │
│  ├── Services: DiveService, ExportService,              │
│  │   ShearwaterCloudImportService, DiveComputerImport   │
│  └── DiveComputer: BLETransport, IOStreamBridge,        │
│      DiveDataMapper, DiveDownloadService                │
├─────────────────────────────────────────────────────────┤
│  Rust Compute Core (stateless, ~500 lines)              │
│  ├── Formula parser (nom-based)                         │
│  ├── Formula evaluator                                  │
│  └── Metrics: DiveStats, SegmentStats                   │
├─────────────────────────────────────────────────────────┤
│  libdivecomputer (C, LGPL 2.1)                          │
│  └── Dive computer protocol parsing (Shearwater, etc.)  │
└─────────────────────────────────────────────────────────┘
```

## Storage

- **GRDB** (Swift SQLite wrapper) with explicit migrations (001–007) in `DivelogDatabase.swift`.
- Schema supports: dives, samples, segments, devices, sites, teammates, equipment, gas mixes, tags, formulas, settings.
- Fingerprint-based deduplication for dive computer imports.
- Multi-computer merge: dives from different computers within a 120-second window are grouped under a shared `groupId`.

## BLE dive computer import

1. CoreBluetooth discovers BLE dive computers.
2. `BLETransport` protocol abstracts the BLE characteristic read/write.
3. `IOStreamBridge` adapts BLETransport to libdivecomputer's `dc_custom_cbs_t`.
4. libdivecomputer handles protocol-specific parsing (Shearwater Petrel, Perdix, etc.).
5. `DiveDataMapper` converts libdivecomputer fields/samples to Profundum models.
6. Progressive save: each parsed dive is persisted immediately via `onDive` callback.

## Formula engine

- Users define calculated fields using dive/segment variables.
- Expressions are parsed (nom) and evaluated in the Rust compute core.
- Results are stored per-dive for use in list columns, filters, and summaries.
- See [FORMULAS.md](FORMULAS.md) for grammar and variable reference.

## FFI boundary

UniFFI generates Swift bindings from `core/src/divelog_compute.udl`. The interface is minimal (~5 functions): `validate_formula`, `evaluate_formula`, `compute_dive_stats`, `compute_segment_stats`, `supported_functions`. See [uniffi-build.md](uniffi-build.md) for build pipeline details.

## Design principles

- **Local-first**: no network calls without explicit user action.
- **Privacy-first**: all data stored locally; cloud sync is a future opt-in feature.
- **Stateless Rust**: the compute core has no state, no storage, no side effects.
- **Swift-owned storage**: all CRUD operations and schema migrations are in Swift/GRDB.

## Performance targets

- List: 10k dives with search and filters under 100 ms.
- Charts: render 5k samples under 50 ms on mid-tier hardware.
