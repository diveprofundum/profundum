# Decision Log

## 2026-01: UI strategy
- Apple platforms use native SwiftUI via a single multiplatform app (Profundum).
- Android, Windows, and web are on the roadmap but deferred. When they land, they will likely use platform-native UI with the shared Rust compute core.
- Original plan for Compose Multiplatform was shelved in favor of focusing on Apple platforms first.

## 2026-01: Hybrid architecture (Swift storage + Rust compute)
- Rust compute core is stateless — formula parsing, evaluation, and metrics computation only.
- Swift/GRDB owns all storage, CRUD, queries, and schema migrations.
- This avoids duplicating SQLite across Rust and Swift and keeps the FFI surface minimal.
- Original plan had Rust owning storage (rusqlite); abandoned because GRDB is more idiomatic for Swift and avoids FFI complexity for every query.

## 2026-01: BLE via libdivecomputer
- BLE dive computer protocol parsing uses libdivecomputer (C library, LGPL 2.1).
- CoreBluetooth provides the transport layer; `IOStreamBridge` adapts it to libdivecomputer's C callbacks.
- Original plan for abstract BLE adapters per platform was replaced with direct libdivecomputer integration — simpler and battle-tested.

## 2026-01: Design system
- "Abyssal Instruments" design tokens (typography, color, spacing) defined in `design_tokens.json`.
- SwiftUI components map tokens to native modifiers.

## 2026-01: Performance targets
- List queries under 100 ms for 10k dives.
- Charts render 5k samples under 50 ms on mid-tier hardware.

## 2026-02: CI and hosting
- GitHub Actions chosen over GitLab CI — no self-hosted runners needed, macOS runners available out of the box.
- Path filtering (dorny/paths-filter) for per-job triggering: Rust changes only run Rust jobs, etc.

## 2026-02: Monorepo versioning
- Single `VERSION` file as source of truth, synced to `Cargo.toml` and Xcode `MARKETING_VERSION` via scripts.
- `make version-check` in CI ensures manifests stay in sync.

## 2026-02: Branch protection
- PRs required to merge into `main`, 1 approval required.
- Required CI checks: `swift-test`, `version-check`.
- Admin bypass for maintainer.
