# FFI Build Pipeline (Draft)

## Goals
- Generate stable Swift and Kotlin bindings from the Rust core.
- Package native libraries per platform with reproducible builds.
- Keep the core API surface small and well‑versioned.

## Tooling
- Rust core with UniFFI
- Swift package / Xcode integration for Apple targets
- Gradle integration for Android + Compose Desktop

## Rust core layout
- `core/` crate exposes public API (model + services)
- UniFFI interface file (e.g., `core/src/divelog.udl`)
- Versioned API surface and changelog

## Swift pipeline (macOS/iOS)
1. Build Rust static libs for Apple targets (arm64 + x86_64 as needed).
2. Run `uniffi-bindgen` to generate Swift bindings.
3. Package as a Swift Package or XCFramework.
4. Xcode consumes the package and links the native lib.

## Kotlin pipeline (Android + Desktop)
1. Build Rust shared libs for Android ABIs (arm64‑v8a, armeabi‑v7a, x86_64).
2. Build Rust shared libs for desktop (macOS, Windows, Linux).
3. Run `uniffi-bindgen` to generate Kotlin bindings.
4. Package as:
   - Android AAR (JNI libs per ABI + Kotlin bindings)
   - Desktop Gradle module with platform‑specific natives

## Versioning and compatibility
- Semantic versioning for the UniFFI API surface.
- Backward‑compatible changes only in minor versions.
- Breaking changes require coordinated app updates.

## CI expectations
- Build core + bindings for all targets on CI.
- Publish artifacts to local build cache or internal registry.
- Smoke tests: load library, call version, run sample query.
