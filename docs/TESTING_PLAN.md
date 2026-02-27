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
- Coverage collection + Codecov upload (`coverage`).
- Version consistency check (`version-check`).

## Coverage tooling

### Local setup

```bash
# One-time: install cargo-llvm-cov
cargo install cargo-llvm-cov

# Generate lcov reports for both Rust and Swift
make coverage
# Output: coverage/rust-lcov.info, coverage/swift-lcov.info

# Generate HTML report (Rust only — open in browser)
make coverage-report
open coverage/rust-html/index.html

# Run just one language
make rust-coverage
make swift-coverage
```

### CI integration

The `coverage` job in `.github/workflows/ci.yml` runs after `rust-test` and `swift-test` pass:

1. Installs `cargo-llvm-cov` via `taiki-e/install-action` (cached)
2. Builds xcframework, then runs `make rust-coverage` and `make swift-coverage`
3. Uploads both lcov files to Codecov with separate `rust` and `swift` flags
4. `fail_ci_if_error: true` — coverage upload failures block the PR

### Codecov configuration

`codecov.yml` at the repo root defines:

- **Project thresholds**: 95% for both Rust and Swift (with 1% tolerance)
- **Patch threshold**: 90% — new code in a PR must be at least 90% covered
- **Flags**: `rust` (covers `core/src/`) and `swift` (covers `apple/DivelogCore/Sources/`)
- **Ignored paths**: auto-generated code (`RustBridge/Generated/`), untestable code (`DiveComputer/` — requires hardware), tests, UI app, scripts, docs

### Reading coverage reports

- **Codecov PR comments**: every PR gets an inline comment showing overall coverage and diff coverage
- **Codecov dashboard**: `codecov.io/gh/diveprofundum/profundum` — file-level drill-down, historical trends
- **Local HTML**: `make coverage-report` generates `coverage/rust-html/index.html` with per-file line highlighting

### Post-merge setup (one-time)

1. Sign up at [codecov.io](https://codecov.io) with the GitHub repo
2. Copy the upload token to repo Settings → Secrets → `CODECOV_TOKEN`
3. Optionally add a coverage badge to the README
