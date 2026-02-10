# Testing Plan

## Goals
- Validate BLE ingestion, parsing, storage, analytics, and UI flows.
- Ensure CCR-critical calculations (CNS/OTU, deco time, segment stats, O2 rates) are correct.
- Protect performance targets for lists and charts.

## Test layers

### 1) Unit tests (Rust core)
- **Derived metrics**: DiveStats, SegmentStats computation from pure inputs.
- **Formula engine**: syntax validation, variable binding, error handling, ternary expressions.

Coverage targets:
- Formula engine + metrics: 95% branch coverage

### 2) Integration tests (Swift/GRDB)
- **Storage**: CRUD for dives, samples, segments, sites, teammates, equipment.
- **Queries**: DiveQuery builder with filters, depth ranges, pagination.
- **Migrations**: upgrade path through all 7 migrations with sample data.
- **Shearwater import**: multi-computer merge, fingerprint dedup, edge cases.

Coverage targets:
- Storage + query surfaces: 80% line coverage

### 3) BLE / dive computer tests
- **MockBLETransport**: deterministic read/write flows for testability.
- **IOStreamBridge**: verify C callback bridging to Swift transport.
- **DiveDataMapper**: field and sample mapping from libdivecomputer types.
- **Error handling**: permission denied, disconnect mid-transfer, protocol errors.

### 4) UI tests (SwiftUI)
- **Snapshot tests**: key screens (list, detail, charts, formula editor, settings).
- **Navigation tests**: onboarding → sync → list → detail → segments.
- **Accessibility**: VoiceOver audit, large text modes, keyboard navigation on macOS.

Coverage targets:
- Critical flows: 100% exercised by UI tests

### 5) Performance tests
- **List performance**: 10k dives filter response < 100 ms.
- **Chart performance**: render 5k samples < 50 ms.
- **Import performance**: 100-dive Shearwater import under baseline threshold.

### 6) Data import tests
- Shearwater Cloud .db import (implemented — see ShearwaterCloudImportTests).
- Subsurface XML, UDDF, DL7 import (future — see GitHub Issues).

## Test data strategy
- **Synthetic logs**: random and edge-case profiles (deep deco, long shallow, bailout).
- **Golden files**: known Shearwater logs with expected output.
- **In-memory databases**: `DivelogDatabase(path: ":memory:")` for fast, isolated test runs.

## CI pipeline
- GitHub Actions with path filtering.
- Rust tests on Ubuntu runner (`rust-test`, `rust-lint`).
- Swift tests on macOS-14 runner (`swift-test`).
- Version consistency check (`version-check`).
