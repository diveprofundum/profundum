# Decision Log

## 2026-02-06: UI strategy
- Apple platforms use native SwiftUI.
- Android, Windows, and Linux use Compose Multiplatform with a shared UI module.

## 2026-02-06: Shared core
- Rust core with UniFFI bindings for Swift and Kotlin.
- SQLite with FTS5 for tags and notes.

## 2026-02-06: BLE ingestion requirement
- BLE ingestion is required for v1 on all platforms.
- Platform-specific BLE adapters provide a unified interface to the core.

## 2026-02-06: Design system alignment
- Shared design tokens drive parity between SwiftUI and Compose.

## 2026-02-06: Performance targets
- List queries under 100 ms for 10k dives.
- Charts render 5k samples under 50 ms on mid-tier hardware.
