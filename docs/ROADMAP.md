# Roadmap

## Completed

### Phase 0: Scaffolding
- Rust compute core crate with UniFFI bindings
- Initial SQLite schema and GRDB migrations
- macOS + iOS app shells (later consolidated into Profundum multiplatform app)

### Phase 1: Core data layer
- GRDB schema with 7 migrations (devices, dives, samples, segments, tags, gas mixes, fingerprints)
- CRUD for all entities (dives, samples, sites, teammates, equipment, formulas)
- Formula engine: nom-based parser and evaluator in Rust
- Derived metrics: DiveStats, SegmentStats computation
- Batch APIs and calculated fields

### Phase 2: UI wiring
- Profundum multiplatform SwiftUI app (iOS + macOS)
- Dive list with filtering, search, and pagination
- Dive detail with depth profile and PPO2 charts (Swift Charts)
- Library views: sites, teammates, equipment, devices
- Settings, new dive sheet, formula list
- VoiceOver accessibility pass

### Phase 3: Dive computer import
- BLE transport layer with CoreBluetooth
- libdivecomputer integration via XCFramework
- Shearwater Cloud .db file import with multi-computer merge
- DiveDataMapper for libdivecomputer → Profundum model conversion
- Fingerprint-based deduplication

### Infrastructure
- GitHub Actions CI with path filtering (rust-lint, rust-test, swift-test, version-check)
- Makefile with dependency chain
- Monorepo versioning (VERSION file, sync/check scripts)
- UniFFI XCFramework build pipeline

## Current priorities

See [GitHub Issues](https://github.com/diveprofundum/profundum/issues) for the active backlog. Key areas:

- **Charts**: temperature overlay, deco ceiling overlay, tank pressure chart, statistics dashboard
- **Import**: live BLE import UI, Subsurface XML, UDDF, DL7 format support
- **UI polish**: export/share sheet, formula management wiring, dive editing

## Future

- **Cloud sync**: opt-in, local-first, privacy-first design (architecture TBD)
- **Multi-platform**: Android (Kotlin/Compose), Windows, Web — scaffolded in `apps/` directory
- **Community dive sites**: shared site database integration
