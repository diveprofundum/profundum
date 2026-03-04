import Combine
import CoreBluetooth
import DivelogCore
import os
#if os(iOS)
import UIKit
#endif

private let importLog = Logger(subsystem: "com.divelog.profundum", category: "ImportSession")

enum ImportPhase: Equatable {
    case idle
    case scanning
    case connecting(DiscoveredDevice)
    case paired(Device)
    case importing(Device)
    case completed(ImportResult)
    case error(ImportError)

    static func == (lhs: ImportPhase, rhs: ImportPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.scanning, .scanning):
            return true
        case (.connecting(let a), .connecting(let b)):
            return a.id == b.id
        case (.paired(let a), .paired(let b)):
            return a.id == b.id
        case (.importing(let a), .importing(let b)):
            return a.id == b.id
        case (.completed(let a), .completed(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

struct ImportResult: Equatable {
    let newDives: Int
    let mergedDives: Int
    let skippedDives: Int
    let deviceName: String
    let autoStopped: Bool
}

enum ImportError: Equatable {
    case bluetoothOff
    case bluetoothUnauthorized
    case connectionFailed(String)
    case downloadFailed(String)
    case importUnavailable

    var message: String {
        switch self {
        case .bluetoothOff:
            return "Bluetooth is turned off. Please enable Bluetooth to scan for dive computers."
        case .bluetoothUnauthorized:
            return "Bluetooth access is not authorized. Please grant Bluetooth permission in Settings."
        case .connectionFailed(let detail):
            return "Failed to connect: \(detail)"
        case .downloadFailed(let detail):
            return "Failed to download dives: \(detail)"
        case .importUnavailable:
            return "Dive download is not yet available. The libdivecomputer integration is coming in a future update."
        }
    }
}

/// Orchestrates the BLE dive computer import lifecycle: scan → connect → download.
///
/// ## Thread Safety
///
/// `ImportSession` is an `ObservableObject` whose `@Published` properties and
/// mutable state are only mutated on the **MainActor**.
///
/// `isCancelled` is `nonisolated(unsafe)` because it is read from the detached
/// download task's `onCancel` closure (which runs on `DiveDownloadService`'s
/// serial queue). Safety is ensured by:
/// 1. Writes happen on MainActor (`startImport` sets `false`, `cancelImport`/
///    `reset` sets `true`) — all before or after the download task runs.
/// 2. The download task reads it via `onCancel` on a serial queue, so reads
///    are ordered. A torn read of `Bool` is benign (worst case: one extra
///    iteration before cancellation is observed).
class ImportSession: ObservableObject {
    @Published var phase: ImportPhase = .idle
    @Published var statusMessage: String = ""
    @Published var downloadProgress: (current: Int, total: Int?)?
    @Published var isFirstSync = false

    let scanner: BLEScanner
    private var diveService: DiveService?
    private var importService: DiveComputerImportService?
    private var downloader: DiveDownloader?
    private var cancellables = Set<AnyCancellable>()
    private var connectionTimeoutTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    /// Read from the detached download task's `onCancel` closure.
    /// Safe because writes only happen on MainActor before/after the task runs.
    /// See class-level doc comment for the full thread safety rationale.
    nonisolated(unsafe) private var isCancelled = false

    init() {
        scanner = BLEScanner()
        downloader = makeDiveDownloader()
        // Forward scanner's changes so SwiftUI re-renders (nested ObservableObject)
        scanner.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        observeScanner()
    }

    func configure(diveService: DiveService, importService: DiveComputerImportService) {
        self.diveService = diveService
        self.importService = importService
    }

    func startScan() {
        guard scanner.managerState == .poweredOn else {
            if scanner.managerState == .unauthorized {
                phase = .error(.bluetoothUnauthorized)
            } else {
                phase = .error(.bluetoothOff)
            }
            return
        }
        phase = .scanning
        statusMessage = "Scanning for dive computers..."
        scanner.startScanning()
    }

    func selectDevice(_ device: DiscoveredDevice) {
        phase = .connecting(device)
        statusMessage = "Connecting to \(device.name ?? "device")..."
        scanner.connect(device.peripheral)

        // Timeout after 15 seconds
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            if case .connecting = self?.phase {
                self?.scanner.disconnect()
                self?.phase = .error(.connectionFailed(
                    "Connection timed out. "
                    + "Make sure the dive computer is awake and in range."
                ))
            }
        }
    }

    func startImport(forceFullSync: Bool = false, cutoffTime: Date? = nil) {
        guard case .paired(let device) = phase else { return }
        phase = .importing(device)
        statusMessage = "Preparing to download dives..."
        isCancelled = false
        downloadProgress = nil

        guard let downloader else {
            phase = .error(.importUnavailable)
            return
        }

        guard let transport = scanner.transport else {
            phase = .error(.downloadFailed("BLE transport not available. Try reconnecting."))
            return
        }

        guard let importService else {
            phase = .error(.downloadFailed("Import service not configured."))
            return
        }

        // Get BLE device name for libdivecomputer descriptor matching
        guard let peripheral = scanner.connectedPeripheral,
              let bleName = peripheral.name, !bleName.isEmpty else {
            phase = .error(.downloadFailed("BLE device name not available. Try reconnecting."))
            return
        }

        // Look up last fingerprint for incremental sync
        let lastFP: Data? = forceFullSync ? nil : (try? importService.lastFingerprint(deviceId: device.id))

        // Wrap transport with tracing for protocol-level I/O visibility
        let tracingTransport = TracingBLETransport(wrapping: transport)

        // Keep screen awake during import — iOS throttles BLE when the screen locks,
        // causing mid-transfer failures on slow dive computers (e.g. Halcyon Symbios).
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif

        // Enable BLE-level logging for real-device debugging
        BLEPeripheralTransport.enableLogging = true

        let tracker = ImportProgressTracker()

        downloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Progress-aware retry: keep reconnecting as long as new dives are
            // being downloaded. Some devices (e.g. Halcyon Symbios) can only
            // handle one dive download per BLE session before needing a fresh
            // connection. Give up after consecutive failures with no new saves.
            let maxNoProgress = 2
            var consecutiveNoProgress = 0
            var attempt = 0
            var currentTransport: TracingBLETransport = tracingTransport

            // Refreshable fingerprint for incremental sync — updated after each
            // successful attempt so libdivecomputer skips already-downloaded dives.
            var currentLastFP = lastFP

            while consecutiveNoProgress < maxNoProgress {
                attempt += 1
                let savedBefore = tracker.saved
                let mergedBefore = tracker.merged

                // Pre-download delay — let BLE stack settle after GATT setup
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { break }

                do {
                    let result = try downloader.download(
                        transport: currentTransport,
                        deviceName: bleName,
                        lastFingerprint: currentLastFP,
                        onDive: { parsed in
                            // Cutoff check (libdivecomputer enumerates newest-first)
                            if let cutoff = cutoffTime,
                               parsed.startTimeUnix < Int64(cutoff.timeIntervalSince1970) {
                                self.isCancelled = true
                                return
                            }

                            // Save each dive immediately as it arrives
                            let outcome = (try? importService.saveImportedDive(
                                parsed, deviceId: device.id
                            )) ?? .skipped
                            tracker.record(outcome)

                            // Auto-stop: 10 consecutive skips (only when no explicit cutoff)
                            if tracker.shouldAutoStop && cutoffTime == nil {
                                self.isCancelled = true
                            }

                            let s = tracker.saved
                            let m = tracker.merged
                            let k = tracker.skipped
                            Task { @MainActor [weak self] in
                                var parts: [String] = []
                                if s > 0 { parts.append("\(s) saved") }
                                if m > 0 { parts.append("\(m) merged") }
                                if k > 0 { parts.append("\(k) skipped") }
                                let msg = parts.isEmpty
                                    ? "Processing..."
                                    : parts.joined(separator: ", ") + "..."
                                self?.statusMessage = msg
                            }
                        },
                        onProgress: { progress in
                            Task { @MainActor [weak self] in
                                self?.downloadProgress = (progress.currentDive, progress.totalDives)
                            }
                        },
                        onCancel: { [weak self] in
                            self?.isCancelled ?? true
                        }
                    )

                    // Success — update device info and show results
                    await self.updateDeviceInfo(device: device, result: result)

                    BLEPeripheralTransport.enableLogging = false
                    #if os(iOS)
                    await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
                    #endif
                    if attempt > 1 {
                        importLog.info("Import completed on attempt \(attempt)")
                    }
                    let saved = tracker.saved
                    let merged = tracker.merged
                    let skipped = tracker.skipped
                    let autoStopped = tracker.shouldAutoStop
                    await MainActor.run {
                        self.phase = .completed(ImportResult(
                            newDives: saved,
                            mergedDives: merged,
                            skippedDives: skipped,
                            deviceName: device.displayName,
                            autoStopped: autoStopped
                        ))
                        if saved > 0 && merged > 0 {
                            let sp = saved == 1 ? "" : "s"
                            let mp = merged == 1 ? "" : "s"
                            self.statusMessage =
                                "\(saved) new dive\(sp) imported, \(merged) dive\(mp) merged"
                                + " from \(device.displayName)."
                        } else if saved > 0 {
                            let sp = saved == 1 ? "" : "s"
                            self.statusMessage =
                                "\(saved) new dive\(sp) imported from \(device.displayName)."
                        } else if merged > 0 {
                            let mp = merged == 1 ? "" : "s"
                            self.statusMessage =
                                "\(merged) dive\(mp) merged from \(device.displayName)."
                        } else {
                            self.statusMessage = "All dives already imported."
                        }
                    }
                    return

                } catch DiveComputerError.cancelled {
                    importLog.info("Import cancelled — dumping I/O trace")
                    currentTransport.dumpTrace()
                    BLEPeripheralTransport.enableLogging = false
                    #if os(iOS)
                    await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
                    #endif
                    let saved = tracker.saved
                    let merged = tracker.merged
                    let skipped = tracker.skipped
                    let autoStopped = tracker.shouldAutoStop
                    await MainActor.run {
                        if saved > 0 || merged > 0 {
                            self.phase = .completed(ImportResult(
                                newDives: saved,
                                mergedDives: merged,
                                skippedDives: skipped,
                                deviceName: device.displayName,
                                autoStopped: autoStopped
                            ))
                            let total = saved + merged
                            let plural = total == 1 ? "" : "s"
                            self.statusMessage =
                                "Cancelled. \(total) dive\(plural) saved before cancellation."
                        } else {
                            self.phase = .paired(device)
                            self.statusMessage = "Download cancelled."
                        }
                        self.downloadProgress = nil
                    }
                    return

                } catch {
                    let newSaves = tracker.saved - savedBefore
                    let newMerges = tracker.merged - mergedBefore
                    let madeProgress = newSaves > 0 || newMerges > 0

                    let errDesc = error.localizedDescription
                    importLog.error(
                        "Attempt \(attempt) (\(newSaves) new, \(newMerges) merged): \(errDesc, privacy: .public)"
                    )
                    currentTransport.dumpTrace()

                    let retryable = (error as? DiveComputerError)?.isRetryable ?? true
                    if !retryable {
                        // Non-retryable — report error with partial results
                        await self.finalizeOnError(
                            tracker: tracker, device: device, error: error
                        )
                        return
                    }

                    if madeProgress {
                        consecutiveNoProgress = 0
                        importLog.info(
                            "Downloaded \(newSaves) new dives before session loss — reconnecting"
                        )
                    } else {
                        consecutiveNoProgress += 1
                        importLog.info(
                            "No new dives this attempt — no-progress count: \(consecutiveNoProgress)/\(maxNoProgress)"
                        )
                        if consecutiveNoProgress >= maxNoProgress {
                            await self.finalizeOnError(
                                tracker: tracker, device: device, error: error
                            )
                            return
                        }
                    }

                    // Update UI — differentiate session reset from connection failure
                    await MainActor.run {
                        if madeProgress {
                            self.statusMessage = "Connection reset — continuing import..."
                        } else {
                            self.statusMessage = "Connection issue — retrying..."
                        }
                    }

                    // Reconnect
                    guard !Task.isCancelled,
                          let newTransport = await self.reconnect(
                              peripheral: peripheral
                          ) else {
                        await self.finalizeOnReconnectFailure(
                            tracker: tracker, device: device
                        )
                        return
                    }
                    currentTransport = TracingBLETransport(wrapping: newTransport)
                    // Only reset if user hasn't cancelled during reconnect
                    guard !Task.isCancelled else { continue }
                    self.isCancelled = false
                    tracker.resetConsecutiveSkips()

                    // Refresh fingerprint so libdivecomputer skips dives we
                    // already saved, avoiding redundant re-enumeration.
                    currentLastFP = try? importService.lastFingerprint(
                        deviceId: device.id
                    )
                }
            }

            // Safety net: if the while loop exits without returning (e.g. Task
            // cancelled at the sleep guard), ensure idle timer is re-enabled.
            BLEPeripheralTransport.enableLogging = false
            #if os(iOS)
            await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
            #endif
        }
    }

    func cancelImport() {
        isCancelled = true
        downloadTask?.cancel()
    }

    func cancelScan() {
        scanner.stopScanning()
        scanner.disconnect()
        connectionTimeoutTask?.cancel()
        phase = .idle
        statusMessage = ""
    }

    func reset() {
        isCancelled = true
        downloadTask?.cancel()
        scanner.stopScanning()
        scanner.disconnect()
        connectionTimeoutTask?.cancel()
        phase = .idle
        statusMessage = ""
        downloadProgress = nil
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    // MARK: - Private

    private func observeScanner() {
        // Observe transport readiness (service/characteristic discovery complete)
        scanner.$transport
            .receive(on: RunLoop.main)
            .sink { [weak self] transport in
                guard let self else { return }
                guard case .connecting(let discovered) = self.phase else { return }

                if transport != nil, let peripheral = self.scanner.connectedPeripheral {
                    self.connectionTimeoutTask?.cancel()
                    let device = self.createOrUpdateDevice(for: discovered, peripheral: peripheral)
                    // Detect first sync (no prior fingerprint for this device)
                    self.isFirstSync = (try? self.importService?.lastFingerprint(deviceId: device.id)) == nil
                    self.phase = .paired(device)
                    self.statusMessage = "Connected to \(device.displayName)"
                }
            }
            .store(in: &cancellables)

        scanner.$managerState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                if case .scanning = self.phase, state != .poweredOn {
                    self.phase = .error(.bluetoothOff)
                }
            }
            .store(in: &cancellables)
    }

    /// Disconnects, waits for the device to reset, reconnects, and waits for
    /// a new BLE transport to become available.
    ///
    /// - Parameter peripheral: The `CBPeripheral` to reconnect to.
    /// - Returns: The new transport, or `nil` if reconnection timed out.
    private func reconnect(peripheral: CBPeripheral) async -> BLEPeripheralTransport? {
        await MainActor.run { scanner.disconnect() }

        // Give the device time to reset its BLE stack
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return nil }

        await MainActor.run { scanner.connect(peripheral) }

        // Poll for transport readiness (15s timeout, 250ms interval)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if Task.isCancelled { return nil }
            let transport = await MainActor.run { scanner.transport }
            if let transport { return transport }
            try? await Task.sleep(for: .milliseconds(250))
        }
        importLog.error("Reconnect timed out after 15s")
        return nil
    }

    /// Shared cleanup for non-retryable errors or exhausted retries.
    /// Shows partial results if any dives were saved.
    private func finalizeOnError(
        tracker: ImportProgressTracker, device: Device, error: Error
    ) async {
        BLEPeripheralTransport.enableLogging = false
        #if os(iOS)
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        let saved = tracker.saved
        let merged = tracker.merged
        let skipped = tracker.skipped
        let autoStopped = tracker.shouldAutoStop
        await MainActor.run {
            if saved > 0 || merged > 0 {
                self.phase = .completed(ImportResult(
                    newDives: saved,
                    mergedDives: merged,
                    skippedDives: skipped,
                    deviceName: device.displayName,
                    autoStopped: autoStopped
                ))
                let total = saved + merged
                let plural = total == 1 ? "" : "s"
                self.statusMessage =
                    "Connection lost. \(total) dive\(plural) saved before the error."
            } else {
                self.phase = .error(.downloadFailed(error.localizedDescription))
            }
        }
    }

    /// Shared cleanup when reconnection fails or is cancelled.
    private func finalizeOnReconnectFailure(
        tracker: ImportProgressTracker, device: Device
    ) async {
        BLEPeripheralTransport.enableLogging = false
        #if os(iOS)
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        let saved = tracker.saved
        let merged = tracker.merged
        let skipped = tracker.skipped
        let autoStopped = tracker.shouldAutoStop
        await MainActor.run {
            if Task.isCancelled {
                if saved > 0 || merged > 0 {
                    self.phase = .completed(ImportResult(
                        newDives: saved,
                        mergedDives: merged,
                        skippedDives: skipped,
                        deviceName: device.displayName,
                        autoStopped: autoStopped
                    ))
                    let total = saved + merged
                    let plural = total == 1 ? "" : "s"
                    self.statusMessage =
                        "Cancelled. \(total) dive\(plural) saved before cancellation."
                } else {
                    self.phase = .paired(device)
                    self.statusMessage = "Download cancelled."
                }
                self.downloadProgress = nil
            } else if saved > 0 || merged > 0 {
                self.phase = .completed(ImportResult(
                    newDives: saved,
                    mergedDives: merged,
                    skippedDives: skipped,
                    deviceName: device.displayName,
                    autoStopped: autoStopped
                ))
                let total = saved + merged
                let plural = total == 1 ? "" : "s"
                self.statusMessage =
                    "Connection lost. \(total) dive\(plural) saved before the error."
            } else {
                self.phase = .error(.downloadFailed(
                    "Failed to reconnect to \(device.displayName). Please try again."
                ))
            }
        }
    }

    private func createOrUpdateDevice(
        for discovered: DiscoveredDevice,
        peripheral: CBPeripheral
    ) -> Device {
        let bleUuid = peripheral.identifier.uuidString
        let vendorName = discovered.knownComputer?.vendorName
        // Use BLE advertised name as model (e.g., "Perdix 2", "Petrel 3")
        // rather than just the vendor name, since libdivecomputer's
        // descriptor match may return a wrong product name for newer models.
        var model = discovered.name
            ?? vendorName
            ?? "Unknown Dive Computer"
        var serialNumber = ""

        // Some devices (e.g. Halcyon Symbios) advertise their serial number
        // as the BLE name instead of a model name. Parse it out.
        if let bleName = discovered.name,
           let parsed = discovered.knownComputer?.parseDeviceName(bleName) {
            model = parsed.model
            serialNumber = parsed.serial
        }

        // Try to find existing device by BLE UUID
        do {
            if var existing = try diveService?.listDevices(includeArchived: true)
                .first(where: { $0.bleUuid == bleUuid }) {
                existing.lastSyncUnix = Int64(Date().timeIntervalSince1970)
                // Backfill manufacturer if not set
                if (existing.manufacturer ?? "").isEmpty, let vendorName {
                    existing.manufacturer = vendorName
                }
                // Always update model from BLE advertised name — it comes
                // from the device hardware and is more accurate than
                // libdivecomputer's descriptor match.
                if let bleName = discovered.name, !bleName.isEmpty {
                    if let parsed = discovered.knownComputer?.parseDeviceName(bleName) {
                        existing.model = parsed.model
                        if existing.serialNumber.isEmpty {
                            existing.serialNumber = parsed.serial
                        }
                    } else {
                        existing.model = bleName
                    }
                }
                do {
                    try diveService?.saveDevice(existing)
                } catch {
                    importLog.error("Failed to update device: \(error.localizedDescription, privacy: .public)")
                }
                return existing
            }
        } catch {
            importLog.error("Failed to list devices: \(error.localizedDescription, privacy: .public)")
        }

        // Create new device
        let device = Device(
            model: model,
            serialNumber: serialNumber,
            firmwareVersion: "",
            lastSyncUnix: Int64(Date().timeIntervalSince1970),
            bleUuid: bleUuid,
            manufacturer: vendorName
        )
        do {
            try diveService?.saveDevice(device)
        } catch {
            importLog.error("Failed to save new device: \(error.localizedDescription, privacy: .public)")
        }
        return device
    }

    @MainActor
    private func updateDeviceInfo(device: Device, result: DownloadResult) {
        guard result.serialNumber != nil || result.firmwareVersion != nil
            || result.vendorName != nil || result.productName != nil else { return }
        var updated = device
        if let serial = result.serialNumber, !serial.isEmpty {
            updated.serialNumber = serial
        }
        if let firmware = result.firmwareVersion, !firmware.isEmpty {
            updated.firmwareVersion = firmware
        }
        if let vendor = result.vendorName, !vendor.isEmpty {
            updated.manufacturer = vendor
        }
        if let product = result.productName, !product.isEmpty,
           Device.genericModelNames.contains(updated.model)
            || updated.model.allSatisfy(\.isNumber) {
            updated.model = product
        }
        updated.lastSyncUnix = Int64(Date().timeIntervalSince1970)
        do {
            try diveService?.saveDevice(updated)
        } catch {
            importLog.error("Failed to save device info: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Cross-source merge: check if a device with the same serial already exists
        // (e.g. from Shearwater Cloud import) and merge them
        do {
            if let serial = result.serialNumber, !serial.isEmpty,
               let existing = try diveService?.findDeviceBySerial(serial, excludingId: updated.id) {
                let devId = existing.id
                importLog.info(
                    "Found device \(devId, privacy: .public) serial \(serial, privacy: .public) — merging"
                )
                try diveService?.mergeDevices(winnerId: existing.id, loserId: updated.id)
            }
        } catch {
            importLog.error("Failed to merge devices: \(error.localizedDescription, privacy: .public)")
        }
    }
}
