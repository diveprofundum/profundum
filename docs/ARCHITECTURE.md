# Architecture

## Goals
- Native macOS + iOS apps with a shared backend core.
- Local-first data store; optional cloud sync later.
- Clean separation between BLE ingestion, parsing, storage, and analytics.

## Proposed core
- **Language**: Rust
- **FFI**: UniFFI to Swift
- **Storage**: SQLite (via rusqlite or sqlite wrapper)
- **Query**: SQLite + FTS5 for notes/tags

## BLE adapter strategy
- Each platform provides a thin native BLE adapter:
  - Apple: CoreBluetooth
  - Android: BLE stack via Kotlin
  - Windows: WinRT BLE
  - Linux: BlueZ (D-Bus)
- The Rust core owns protocol parsing, validation, and normalization.
- BLE adapters expose a unified interface to the core via FFI.

## Segment analytics
- Segments are first-class entities with start/end times, tags, and notes.
- Segment stats are derived (avg depth, CNS/OTU, time at setpoint, gas usage).
- Charts support selection to compute segment metrics on the fly.

## Formula-driven analytics
- Users can define formulas using named fields (e.g. `deco_time_min / bottom_time_min`).
- Formulas produce calculated fields stored per dive for list and summary views.

## Data flow
1. BLE session manager connects to Shearwater devices.
2. Raw log chunks are decoded and validated (CRC).
3. Parser produces normalized `Dive` + `Sample` records.
4. Store persists in SQLite.
5. Query layer powers filters/tags/analytics.

## App integration (macOS + iOS + Android + Windows + Linux)
- Apple platforms use native SwiftUI apps.
- Android, Windows, and Linux share a Compose Multiplatform UI codebase.
- Native apps call into the Rust core via UniFFI for:
  - device discovery + sync
  - dive list and detail queries
  - calculated metrics
- Platform UI frameworks own navigation, view state, and presentation only.

## FFI bindings and packaging
- Swift bindings generated via UniFFI and linked into macOS/iOS targets.
- Kotlin bindings generated via UniFFI and packaged as:
  - Android AAR (JNI + Rust static/shared lib)
  - Desktop JVM dependency (platform-specific native libs)

## Design system alignment
- Shared design tokens (type scale, spacing, color, density) defined once.
- SwiftUI and Compose map tokens to native components with parity targets.

## Storage and schema evolution
- Use explicit schema versioning and migrations.
- Provide forward-compatible export/import for long-term data safety.

## Rich metadata
- Sites, buddies, and equipment are modeled as first-class entities.
- Dive records reference these entities for reuse and consistency.

## Performance targets
- List: 10k dives with search and filters under 100 ms response.
- Charts: render 5k samples under 50 ms on mid-tier hardware.

## Key interfaces
- BLE transport abstraction
- Parser for Shearwater binary logs
- Storage API (CRUD + query)
- Analytics API (derived metrics)

## Milestones
1. Core data model + storage schema
2. Import pipeline stub (fake device/logs for UI testing)
3. SwiftUI shells wired to core queries
4. BLE connection + real ingestion
