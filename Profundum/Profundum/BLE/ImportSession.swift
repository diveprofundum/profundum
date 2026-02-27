import Combine
import CoreBluetooth
import DivelogCore
import os

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
        guard let bleName = scanner.connectedPeripheral?.name, !bleName.isEmpty else {
            phase = .error(.downloadFailed("BLE device name not available. Try reconnecting."))
            return
        }

        // Look up last fingerprint for incremental sync
        let lastFP: Data? = forceFullSync ? nil : (try? importService.lastFingerprint(deviceId: device.id))

        // Wrap transport with tracing for protocol-level I/O visibility
        let tracingTransport = TracingBLETransport(wrapping: transport)

        // Enable BLE-level logging for real-device debugging
        BLEPeripheralTransport.enableLogging = true

        let tracker = ImportProgressTracker()

        downloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                let result = try downloader.download(
                    transport: tracingTransport,
                    deviceName: bleName,
                    lastFingerprint: lastFP,
                    onDive: { parsed in
                        // Cutoff check (libdivecomputer enumerates newest-first)
                        if let cutoff = cutoffTime,
                           parsed.startTimeUnix < Int64(cutoff.timeIntervalSince1970) {
                            self.isCancelled = true
                            return
                        }

                        // Save each dive immediately as it arrives
                        let outcome = (try? importService.saveImportedDive(parsed, deviceId: device.id)) ?? .skipped
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
                            let msg = parts.isEmpty ? "Processing..." : parts.joined(separator: ", ") + "..."
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

                // Update device with serial/firmware/vendor/product and merge cross-source
                await self.updateDeviceInfo(device: device, result: result)

                BLEPeripheralTransport.enableLogging = false
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
                            "\(saved) new dive\(sp) imported, \(merged) dive\(mp) merged from \(device.displayName)."
                    } else if saved > 0 {
                        let sp = saved == 1 ? "" : "s"
                        self.statusMessage = "\(saved) new dive\(sp) imported from \(device.displayName)."
                    } else if merged > 0 {
                        let mp = merged == 1 ? "" : "s"
                        self.statusMessage = "\(merged) dive\(mp) merged from \(device.displayName)."
                    } else {
                        self.statusMessage = "All dives already imported."
                    }
                }
            } catch DiveComputerError.cancelled {
                importLog.info("Import cancelled — dumping I/O trace")
                tracingTransport.dumpTrace()
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
                        self.statusMessage = "Cancelled. \(total) dive\(plural) saved before cancellation."
                    } else {
                        self.phase = .paired(device)
                        self.statusMessage = "Download cancelled."
                    }
                    self.downloadProgress = nil
                }
            } catch {
                importLog.error("Import failed: \(error.localizedDescription) — dumping I/O trace")
                tracingTransport.dumpTrace()
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
                        self.statusMessage = "Connection lost. \(total) dive\(plural) saved before the error."
                    } else {
                        self.phase = .error(.downloadFailed(error.localizedDescription))
                    }
                }
            }
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

    private func createOrUpdateDevice(
        for discovered: DiscoveredDevice,
        peripheral: CBPeripheral
    ) -> Device {
        let bleUuid = peripheral.identifier.uuidString
        let vendorName = discovered.knownComputer?.vendorName
        // Use BLE advertised name as model (e.g., "Perdix 2", "Petrel 3")
        // rather than just the vendor name, since libdivecomputer's
        // descriptor match may return a wrong product name for newer models.
        let model = discovered.name
            ?? vendorName
            ?? "Unknown Dive Computer"

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
                    existing.model = bleName
                }
                do {
                    try diveService?.saveDevice(existing)
                } catch {
                    importLog.error("Failed to update device: \(error.localizedDescription)")
                }
                return existing
            }
        } catch {
            importLog.error("Failed to list devices: \(error.localizedDescription)")
        }

        // Create new device
        let device = Device(
            model: model,
            serialNumber: "",
            firmwareVersion: "",
            lastSyncUnix: Int64(Date().timeIntervalSince1970),
            bleUuid: bleUuid,
            manufacturer: vendorName
        )
        do {
            try diveService?.saveDevice(device)
        } catch {
            importLog.error("Failed to save new device: \(error.localizedDescription)")
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
           Device.genericModelNames.contains(updated.model) {
            updated.model = product
        }
        updated.lastSyncUnix = Int64(Date().timeIntervalSince1970)
        do {
            try diveService?.saveDevice(updated)
        } catch {
            importLog.error("Failed to save device info: \(error.localizedDescription)")
            return
        }

        // Cross-source merge: check if a device with the same serial already exists
        // (e.g. from Shearwater Cloud import) and merge them
        do {
            if let serial = result.serialNumber, !serial.isEmpty,
               let existing = try diveService?.findDeviceBySerial(serial, excludingId: updated.id) {
                importLog.info(
                    "Found existing device \(existing.id) with serial \(serial) — merging"
                )
                try diveService?.mergeDevices(winnerId: existing.id, loserId: updated.id)
            }
        } catch {
            importLog.error("Failed to merge devices: \(error.localizedDescription)")
        }
    }
}
