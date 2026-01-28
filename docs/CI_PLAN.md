# CI Plan (Draft)

## Assumptions
- GitLab CI is used with Linux and macOS runners; Windows runner optional.
- Builds are local‑first; no network needed during tests.

## Jobs
### 1) Rust core (Linux)
- `cargo fmt --check`
- `cargo clippy --all-targets --all-features`
- `cargo test`

### 2) Rust core (macOS)
- `cargo test` (ensures Apple compatibility)

### 3) SwiftUI (macOS)
- Build macOS app target
- Snapshot tests (dashboard, list, detail, formula builder)

### 4) Compose (Linux or Windows)
- Build Compose Desktop target
- Run UI tests + screenshot tests

### 5) Artifacts
- Upload test snapshots and logs on failure
- Store performance run outputs (list/filter timing, chart render timing)

## Triggers
- Pull requests: all jobs
- Main branch: all jobs + nightly perf run

## GitLab pipeline
- See `.gitlab-ci.yml` for concrete job definitions.

## Caching
- Rust: `~/.cargo` + target cache
- Kotlin/Gradle: `~/.gradle/caches`
- Swift: DerivedData cache for snapshot tests
