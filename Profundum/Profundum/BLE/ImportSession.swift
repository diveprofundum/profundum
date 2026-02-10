import CoreBluetooth
import DivelogCore
import Combine
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
    let skippedDives: Int
    let deviceName: String
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

class ImportSession: ObservableObject {
    @Published var phase: ImportPhase = .idle
    @Published var statusMessage: String = ""
    @Published var downloadProgress: (current: Int, total: Int?)? = nil

    let scanner: BLEScanner
    private var diveService: DiveService?
    private var importService: DiveComputerImportService?
    private var downloader: DiveDownloader?
    private var cancellables = Set<AnyCancellable>()
    private var connectionTimeoutTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    /// Read from the detached download task's `onCancel` closure.
    /// Safe because writes only happen on MainActor before/after the task runs.
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
                self?.phase = .error(.connectionFailed("Connection timed out. Make sure the dive computer is awake and in range."))
            }
        }
    }

    func startImport() {
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
        // TODO: Remove forceFullSync once BLE stability is verified
        let forceFullSync = true
        let lastFP: Data? = forceFullSync ? nil : (try? importService.lastFingerprint(deviceId: device.id))

        // Wrap transport with tracing for protocol-level I/O visibility
        let tracingTransport = TracingBLETransport(wrapping: transport)

        // Enable BLE-level logging for real-device debugging
        BLEPeripheralTransport.enableLogging = true

        // Counts mutated on the serial download queue, read after download completes.
        // Wrapped in a class so closures capture a reference, not a mutable value.
        let counts = ImportCounts()

        downloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                let result = try downloader.download(
                    transport: tracingTransport,
                    deviceName: bleName,
                    lastFingerprint: lastFP,
                    onDive: { parsed in
                        // Save each dive immediately as it arrives
                        let wasSaved = (try? importService.saveImportedDive(parsed, deviceId: device.id)) ?? false
                        if wasSaved {
                            counts.saved += 1
                        } else {
                            counts.skipped += 1
                        }
                        let s = counts.saved
                        let k = counts.skipped
                        Task { @MainActor [weak self] in
                            self?.statusMessage = "Saved \(s) dive\(s == 1 ? "" : "s") (\(k) skipped)..."
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

                // Update device with serial/firmware if available
                await self.updateDeviceInfo(
                    device: device,
                    serial: result.serialNumber,
                    firmware: result.firmwareVersion
                )

                BLEPeripheralTransport.enableLogging = false
                let saved = counts.saved
                let skipped = counts.skipped
                await MainActor.run {
                    self.phase = .completed(ImportResult(
                        newDives: saved,
                        skippedDives: skipped,
                        deviceName: device.model
                    ))
                    self.statusMessage = saved > 0
                        ? "\(saved) new dive\(saved == 1 ? "" : "s") imported from \(device.model)."
                        : "All dives already imported."
                }
            } catch DiveComputerError.cancelled {
                importLog.info("Import cancelled — dumping I/O trace")
                tracingTransport.dumpTrace()
                let saved = counts.saved
                let skipped = counts.skipped
                await MainActor.run {
                    if saved > 0 {
                        self.phase = .completed(ImportResult(
                            newDives: saved,
                            skippedDives: skipped,
                            deviceName: device.model
                        ))
                        self.statusMessage = "Cancelled. \(saved) dive\(saved == 1 ? "" : "s") saved before cancellation."
                    } else {
                        self.phase = .paired(device)
                        self.statusMessage = "Download cancelled."
                    }
                    self.downloadProgress = nil
                }
            } catch {
                importLog.error("Import failed: \(error.localizedDescription) — dumping I/O trace")
                tracingTransport.dumpTrace()
                let saved = counts.saved
                let skipped = counts.skipped
                await MainActor.run {
                    if saved > 0 {
                        self.phase = .completed(ImportResult(
                            newDives: saved,
                            skippedDives: skipped,
                            deviceName: device.model
                        ))
                        self.statusMessage = "Connection lost. \(saved) dive\(saved == 1 ? "" : "s") saved before the error."
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
                    self.phase = .paired(device)
                    self.statusMessage = "Connected to \(device.model)"
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
        let model = discovered.knownComputer?.vendorName
            ?? discovered.name
            ?? "Unknown Dive Computer"

        // Try to find existing device by BLE UUID
        do {
            if var existing = try diveService?.listDevices(includeArchived: true)
                .first(where: { $0.bleUuid == bleUuid }) {
                existing.lastSyncUnix = Int64(Date().timeIntervalSince1970)
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
            bleUuid: bleUuid
        )
        do {
            try diveService?.saveDevice(device)
        } catch {
            importLog.error("Failed to save new device: \(error.localizedDescription)")
        }
        return device
    }

    @MainActor
    private func updateDeviceInfo(device: Device, serial: String?, firmware: String?) {
        guard serial != nil || firmware != nil else { return }
        var updated = device
        if let serial, !serial.isEmpty {
            updated.serialNumber = serial
        }
        if let firmware, !firmware.isEmpty {
            updated.firmwareVersion = firmware
        }
        updated.lastSyncUnix = Int64(Date().timeIntervalSince1970)
        do {
            try diveService?.saveDevice(updated)
        } catch {
            importLog.error("Failed to update device info: \(error.localizedDescription)")
        }
    }
}

/// Mutable counters shared between the download callbacks and completion handler.
/// All access happens on `DiveDownloadService`'s serial queue, so no data race.
private final class ImportCounts: @unchecked Sendable {
    nonisolated(unsafe) var saved = 0
    nonisolated(unsafe) var skipped = 0
}
