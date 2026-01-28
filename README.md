# Divelog (macOS + iOS, shared backend)

This repo is the starting point for native apps backed by a single cross-platform core. The frontends are separate native apps, while the backend core handles BLE ingestion, parsing, storage, and analytics.

## Why start here
- Shared core reduces duplication across platforms for BLE parsing, derived metrics, and persistence.
- Native UIs keep platform fidelity and enable richer OS integrations.
- Rust + UniFFI is a practical cross-platform core that can be linked into Swift, Kotlin, and other native targets.

## Repo layout
- `core/`: cross-platform backend (Rust)
- `apps/macos/`: macOS app (SwiftUI)
- `apps/ios/`: iOS app (SwiftUI)
- `apps/compose/`: shared Compose Multiplatform UI module
- `apps/android/`: Android app (Compose Multiplatform)
- `apps/desktop/`: Windows + Linux desktop app (Compose Multiplatform)
- `docs/`: architecture + roadmap

## Next steps
See `docs/ARCHITECTURE.md` and `docs/ROADMAP.md` for the initial build plan.
