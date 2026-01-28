# Roadmap

## Phase 0: scaffolding (now)
- Create shared core crate with model + interfaces.
- Define the initial SQLite schema.
- Create macOS + iOS app shells.
- Add Compose Multiplatform module and desktop app target.
- Confirm Compose Multiplatform for Android/Windows/Linux UI.
- Add UniFFI binding scaffolding for Swift and Kotlin.
- Draft design system tokens shared by SwiftUI and Compose.

## Phase 1: core data layer
- Implement schema + migrations.
- CRUD for devices/dives/samples/tags.
- Derived metrics utilities (CCR hours, deco hours, depth classes).
- Storage versioning and export/import compatibility.
- Add first-class entities for sites, buddies, and equipment.
- Add segment model with segment stats computation.
- Add formula engine for calculated fields.

## Phase 2: UI wiring
- Dashboard and dive list in SwiftUI (macOS/iOS).
- Dashboard and dive list in Compose Multiplatform (Android/Windows/Linux).
- Data pulled from the core.
- Sample data generator for UI testing.
- Performance benchmarks for list and chart rendering.
- Dive detail chart with segment selection and annotations.
- Year-in-review summary cards and exportable reports.
 - Onboarding, BLE permissions, and sync UX.
 - Formula library and calculated field columns.
 - Sites, buddies, and equipment management screens.

## Phase 3: BLE ingestion
- Device discovery and connection.
- Log chunk download + CRC.
- Parser + normalizer integrated into storage.
- Platform BLE adapters wired to shared core interface.
 - Robust BLE error handling, resume, and retry.
 - Sync performance targets met for 50 dives under 3 minutes.

## Phase 4: power features
- Tagging grammar + advanced filters.
- Export formats (Subsurface XML, CSV).
- Optional cloud sync.
- If cloud sync is added, evaluate GitOps for infrastructure deployment.
