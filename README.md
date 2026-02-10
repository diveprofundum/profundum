# Profundum

An open-source dive log for iOS and macOS. Local-first, privacy-first.

Profundum records and analyzes scuba dives — open-circuit and closed-circuit rebreather (CCR). It imports dives from Shearwater Cloud databases and BLE dive computers via [libdivecomputer](https://www.libdivecomputer.org/), stores everything locally with GRDB, and uses a Rust compute core for formula parsing and dive metrics.

## Features

- **Dive logging** with depth profiles, gas mixes, deco status, CNS/OTU tracking
- **Multi-computer merge** — dives from multiple computers within a 120-second window are grouped automatically
- **Shearwater Cloud import** — import directly from Shearwater's `.db` export files
- **BLE dive computer import** — connect to dive computers over Bluetooth Low Energy
- **Interactive charts** — depth profile and PPO2 traces with scrub-to-inspect (Swift Charts)
- **Custom formulas** — user-defined calculated fields using dive variables (e.g., `deco_time_min / bottom_time_min`)
- **VoiceOver accessible** — semantic grouping, chart summaries, filter state announcements
- **Export** — JSON export/import for backup and data portability

## Architecture

```
Swift Layer (native)
├── Profundum           SwiftUI multiplatform app (iOS + macOS)
├── DivelogCore         Swift package — GRDB storage, models, services
├── CoreBluetooth       BLE dive computer communication
└── libdivecomputer     C library for dive computer protocol parsing

Rust Compute Core (~500 lines, stateless)
├── Formula parser      nom-based expression parsing and evaluation
└── Metrics engine      DiveStats, SegmentStats from pure inputs
```

Swift owns all storage and UI. Rust handles stateless computation. They communicate via UniFFI-generated bindings packaged as an XCFramework.

## Requirements

- Xcode 15+ (Swift 5.9)
- Rust toolchain (for building the compute core)
- iOS 16+ / macOS 13+

## Building

```bash
# Build everything (Rust XCFramework + Swift package)
make all

# Run all tests (Rust + Swift)
make test

# See all available targets
make help
```

For BLE dive computer support, also build the libdivecomputer XCFramework:

```bash
make libdivecomputer-xcframework
```

See [docs/uniffi-build.md](docs/uniffi-build.md) for details on the Rust-to-Swift build pipeline.

## Repository Layout

```
Profundum/              Multiplatform SwiftUI app (iOS + macOS)
apple/DivelogCore/      Swift package — models, database, services
core/                   Rust compute core (formula parser, metrics)
libdivecomputer/        Submodule + XCFramework build for dive computer protocols
scripts/                Version sync, build verification
docs/                   Architecture and design documents
```

## Development

```bash
# Rust lint + format check
make lint

# Swift tests only
make swift-test

# Rust tests only
make rust-test

# Check monorepo version consistency
make version-check
```

Branch protection is enabled on `main`. All changes go through pull requests with required CI checks (`swift-test`, `version-check`).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines. In short:

1. Create a feature branch
2. Make your changes with tests
3. Open a PR — CI runs automatically
4. Address review feedback and merge

## License

[MIT](LICENSE)
