.PHONY: all test clean rust-test swift-test lint rust-lint swift-lint swift-build \
       xcframework swift-bindings libdivecomputer-xcframework verify help \
       version-check version-sync

# ──────────────────────────────────────────────────────────────
# Default target
# ──────────────────────────────────────────────────────────────
all: xcframework swift-build

# ──────────────────────────────────────────────────────────────
# Rust compute core
# ──────────────────────────────────────────────────────────────

# Build XCFramework from Rust sources for all Apple platforms
xcframework:
	./core/build-xcframework.sh

# Regenerate Swift bindings from the UDL definition
swift-bindings: xcframework
	cd core && cargo run --features=uniffi/cli \
		--bin uniffi-bindgen generate src/divelog_compute.udl \
		--language swift \
		--out-dir ../apple/DivelogCore/Sources/RustBridge/Generated

# Run Rust tests
rust-test:
	cd core && cargo test

# Lint Rust code
rust-lint:
	cd core && cargo fmt --check
	cd core && cargo clippy --all-targets --all-features -- -D warnings

# Lint Swift code
swift-lint:
	swiftlint lint --strict --config .swiftlint.yml

# ──────────────────────────────────────────────────────────────
# libdivecomputer (optional — only needed for BLE dive computer import)
# ──────────────────────────────────────────────────────────────
libdivecomputer-xcframework:
	./libdivecomputer/build-xcframework.sh

# ──────────────────────────────────────────────────────────────
# Swift package (depends on XCFramework being built)
# ──────────────────────────────────────────────────────────────

# Build the Swift package (verifies xcframework is linkable)
swift-build: xcframework
	cd apple/DivelogCore && swift build

# Run Swift tests (rebuilds xcframework first if Rust sources changed)
swift-test: xcframework
	cd apple/DivelogCore && swift test

# ──────────────────────────────────────────────────────────────
# Aggregate targets
# ──────────────────────────────────────────────────────────────

# Run all tests — Rust first (fast, catches compute bugs early), then Swift
test: rust-test swift-test

# Run all linters
lint: rust-lint swift-lint

# Verify XCFramework integrity
verify:
	./scripts/verify-xcframework.sh

# Remove all build artifacts
clean:
	cd core && cargo clean
	rm -rf apple/DivelogCore/DivelogComputeFFI.xcframework
	rm -rf apple/DivelogCore/.build

# ──────────────────────────────────────────────────────────────
# Versioning (single version for the whole monorepo)
# ──────────────────────────────────────────────────────────────

# Check that VERSION file, Cargo.toml, and Xcode project are in sync
version-check:
	./scripts/check-version.sh

# Sync VERSION file to all manifests. Optionally: make version-sync V=0.2.0
version-sync:
	./scripts/sync-version.sh $(V)

# ──────────────────────────────────────────────────────────────
# Help
# ──────────────────────────────────────────────────────────────
help:
	@echo "Divelog Monorepo"
	@echo ""
	@echo "Build targets:"
	@echo "  make all                        Build xcframework + Swift package"
	@echo "  make xcframework                Build Rust → DivelogComputeFFI.xcframework"
	@echo "  make swift-bindings             Regenerate UniFFI Swift bindings"
	@echo "  make swift-build                Build DivelogCore Swift package"
	@echo "  make libdivecomputer-xcframework Build libdivecomputer → XCFramework"
	@echo ""
	@echo "Test targets:"
	@echo "  make test                       Run all tests (Rust + Swift)"
	@echo "  make rust-test                  Run Rust compute core tests"
	@echo "  make swift-test                 Run Swift package tests"
	@echo ""
	@echo "Quality targets:"
	@echo "  make lint                       Run all linters (Rust + Swift)"
	@echo "  make rust-lint                  Run Rust linters (cargo fmt, clippy)"
	@echo "  make swift-lint                 Run SwiftLint on Swift sources"
	@echo "  make verify                     Verify XCFramework integrity"
	@echo ""
	@echo "Versioning:"
	@echo "  make version-check              Verify all manifests match VERSION"
	@echo "  make version-sync               Sync VERSION to all manifests"
	@echo "  make version-sync V=0.2.0       Set new version and sync"
	@echo ""
	@echo "Maintenance:"
	@echo "  make clean                      Remove all build artifacts"
