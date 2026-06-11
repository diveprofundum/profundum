.PHONY: all test clean rust-test swift-test lint rust-lint swift-lint swift-build \
       xcframework swift-bindings libdivecomputer-xcframework verify help \
       version-check version-sync security audit deny mutants \
       coverage rust-coverage swift-coverage coverage-report \
       iphone iphone-build iphone-install iphone-launch

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
# (build-xcframework.sh generates bindings as part of the build)
swift-bindings: xcframework

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
swift-build: swift-bindings
	cd apple/DivelogCore && swift build

# Run Swift tests (rebuilds xcframework + bindings first if Rust sources changed)
swift-test: swift-bindings
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
# iPhone deploy (build + install + launch, no Xcode GUI)
# ──────────────────────────────────────────────────────────────

# Auto-detect the first connected device; override with: make iphone DEVICE=<udid>
DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | grep -E 'connected' | grep -Eo '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
DEVICE_BUILD_DIR := build/device
APP_PATH := $(DEVICE_BUILD_DIR)/Build/Products/Debug-iphoneos/Profundum.app
BUNDLE_ID := azlucis.Profundum

# Build, install, and launch on the connected iPhone
iphone: iphone-install iphone-launch

# Build the app for the connected device (rebuilds xcframework if Rust changed)
iphone-build: swift-bindings
	@test -n "$(DEVICE)" || { echo "error: no connected device found (xcrun devicectl list devices)"; exit 1; }
	xcodebuild build \
		-project Profundum/Profundum.xcodeproj \
		-scheme Profundum \
		-destination 'platform=iOS,id=$(DEVICE)' \
		-derivedDataPath $(DEVICE_BUILD_DIR) \
		-allowProvisioningUpdates \
		-quiet

# Install the built app onto the device
iphone-install: iphone-build
	xcrun devicectl device install app --device $(DEVICE) $(APP_PATH)

# Launch the installed app on the device
iphone-launch:
	@test -n "$(DEVICE)" || { echo "error: no connected device found (xcrun devicectl list devices)"; exit 1; }
	xcrun devicectl device process launch --device $(DEVICE) $(BUNDLE_ID)

# ──────────────────────────────────────────────────────────────
# Security & mutation testing
# ──────────────────────────────────────────────────────────────

# Run all security checks (cargo audit + cargo deny)
security: audit deny

# Check Rust dependencies for known vulnerabilities (RustSec advisory DB)
audit:
	cd core && cargo audit

# Check license compliance, advisories, and dependency bans
deny:
	cd core && cargo deny check

# Run mutation testing on the Rust compute core (slow — use locally, not in CI)
mutants:
	cd core && cargo mutants --timeout 60

# ──────────────────────────────────────────────────────────────
# Coverage
# ──────────────────────────────────────────────────────────────

# Rust coverage via cargo-llvm-cov (install: cargo install cargo-llvm-cov)
rust-coverage:
	mkdir -p coverage
	cd core && cargo llvm-cov --lcov --output-path ../coverage/rust-lcov.info

# Swift coverage via swift test + xcrun llvm-cov
swift-coverage: swift-bindings
	mkdir -p coverage
	cd apple/DivelogCore && swift test --enable-code-coverage
	@PROF=$$(find apple/DivelogCore/.build -name 'DivelogCorePackageTests.xctest' -type d)/Contents/MacOS/DivelogCorePackageTests; \
	PROFDATA=$$(find apple/DivelogCore/.build -name 'default.profdata' -type f | head -1); \
	xcrun llvm-cov export -format=lcov -instr-profile "$$PROFDATA" "$$PROF" \
		-ignore-filename-regex='(Tests/|Generated/|\.build/)' > coverage/swift-lcov.info

# Generate both coverage reports (lcov)
coverage: rust-coverage swift-coverage
	@echo "Coverage reports in coverage/"

# Generate HTML reports for local viewing
coverage-report: coverage
	cd core && cargo llvm-cov --html --output-dir ../coverage/rust-html
	@echo "Rust HTML: coverage/rust-html/index.html"

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
	@echo "Device deploy:"
	@echo "  make iphone                     Build + install + launch on connected iPhone"
	@echo "  make iphone-build               Build only (device binary in build/device/)"
	@echo "  make iphone-install             Build + install (no launch)"
	@echo "  make iphone DEVICE=<udid>       Target a specific device"
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
	@echo "Security & mutation testing:"
	@echo "  make security                   Run all security checks (audit + deny)"
	@echo "  make audit                      Check deps for known vulnerabilities"
	@echo "  make deny                       Check license compliance + advisories"
	@echo "  make mutants                    Run mutation testing on Rust core"
	@echo ""
	@echo "Coverage:"
	@echo "  make coverage                   Generate lcov reports (Rust + Swift)"
	@echo "  make rust-coverage              Rust coverage only (cargo-llvm-cov)"
	@echo "  make swift-coverage             Swift coverage only (llvm-cov export)"
	@echo "  make coverage-report            Generate HTML coverage reports"
	@echo ""
	@echo "Versioning:"
	@echo "  make version-check              Verify all manifests match VERSION"
	@echo "  make version-sync               Sync VERSION to all manifests"
	@echo "  make version-sync V=0.2.0       Set new version and sync"
	@echo ""
	@echo "Maintenance:"
	@echo "  make clean                      Remove all build artifacts"
