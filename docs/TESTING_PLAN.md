# Testing Plan (Draft)

## Goals
- Validate BLE ingestion, parsing, storage, analytics, and UI flows.
- Ensure CCR‑critical calculations (CNS/OTU, deco time, segment stats, O2 rates) are correct.
- Protect performance targets for lists and charts.

## Test layers
### 1) Unit tests (Rust core)
- **Models & parsing**: parse log chunks, CRC checks, field normalization.
- **Derived metrics**: CCR hours, deco hours, depth classes, segment stats.
- **Formula engine**: syntax validation, variable binding, error handling.
- **Migrations**: apply migrations in order, idempotency, version tracking.

Coverage targets:
- Core logic files: 80% line coverage
- Formula engine + metrics: 95% branch coverage

### 2) Integration tests (Rust core)
- **Storage**: CRUD for dives, samples, segments, sites, buddies, equipment.
- **Queries**: tag filters, depth ranges, calculated field columns.
- **Migrations**: upgrade from v1 to v2 with sample data.

Coverage targets:
- Storage + query surfaces: 80% line coverage

### 3) BLE adapter tests (platform)
- **Mock adapter**: deterministic scan/connect/list/download flows.
- **Error taxonomy**: permission denied, Bluetooth off, disconnect mid‑transfer.
- **Resume**: download resumes from offset after failure.

Coverage targets:
- Adapter state machine: 100% transition coverage

### 4) UI tests (SwiftUI + Compose)
- **Snapshot tests**: key screens (list, detail, charts, formula editor, settings).
- **Navigation tests**: onboarding → sync → list → detail → segments.
- **Accessibility**: large text modes, contrast, keyboard navigation on desktop.

Coverage targets:
- Critical flows: 100% exercised by UI tests

### 5) Performance tests
- **List performance**: 10k dives filter response < 100 ms.
- **Chart performance**: render 5k samples < 50 ms.
- **Sync performance**: 50 dives < 3 minutes on mid‑tier hardware.

### 6) Data import tests (v2)
- CSV/Subsurface/UDDF import mapping validation.
- Schema compatibility for older exports.

## Test data strategy
- **Synthetic logs**: random and edge‑case profiles (deep deco, long shallow, bailout).
- **Golden files**: known Shearwater logs with expected output.
- **Property‑based tests**: time ordering, no negative depths, monotonic timestamps.

## CI pipeline
- Rust unit/integration tests on Linux/macOS.
- SwiftUI snapshots on macOS runner.
- Compose UI tests on Linux/Windows.
- Linting and formatting gates.

## Ownership
- Core logic: backend engineer.
- BLE adapters: platform leads.
- UI tests: platform UI owners.
