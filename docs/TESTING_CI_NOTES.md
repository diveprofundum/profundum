# CI and Environment Notes (Draft)

## CI expectations
- Linux: Rust unit/integration tests
- macOS: SwiftUI snapshot tests
- Windows/Linux: Compose UI tests

## Tooling suggestions
- Rust: `cargo test`, `cargo fmt`, `cargo clippy`
- SwiftUI: Snapshot testing (e.g., Point‑Free SnapshotTesting)
- Compose: Paparazzi or Compose UI test framework

## Data artifacts
- Store golden BLE logs under `testdata/` and gate changes via checksums.
- Keep small synthetic datasets for UI performance tests.
