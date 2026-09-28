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
    /// Dives downloaded from the computer that could not be saved.
    var failedDives: Int = 0
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
/// Cancellation is tracked by a lock-protected `CancellationFlag` because it is
/// set from the MainActor (`cancelImport`/`reset`), from the libdivecomputer
/// queue (`onDive` cutoff check), and from the persistence queue (auto-stop),
/// and polled by libdivecomputer through `onCancel`.
class ImportSession: ObservableObject {
    @Published var phase: ImportPhase = .idle
    @Published var statusMessage: String = ""
    @Published var downloadProgress: (current: Int, total: Int?)?
    @Published var isFirstSync = false
    @Published var isNewDevice = false

    let scanner: BLEScanner
    private var diveService: DiveService?
    private var importService: DiveComputerImportService?
    private var downloader: DiveDownloader?
    private var cancellables = Set<AnyCancellable>()
    private var connectionTimeoutTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    /// Shared with the download task's `onDive`/`onCancel` closures and the
    /// persistence queue's auto-stop; see class-level doc comment.
    private let cancellation = CancellationFlag()

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
        cancellation.reset()
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
        let syncFP = forceFullSync ? nil : (try? importService.lastSyncFingerprint(deviceId: device.id))
        let lastFP: Data? = syncFP?.fingerprint

        // Captured now: `scanner.disconnect()` clears it, and the reconnect
        // path and error messages below need it after a disconnect.
        let knownComputer = scanner.connectedKnownComputer
        let cancellation = self.cancellation

        // Wrap transport with tracing for protocol-level I/O visibility
        let tracingTransport = TracingBLETransport(wrapping: transport)
        let initialLink = transport.linkDescription
        importLog.notice("Transport: \(initialLink, privacy: .public)")

        // Keep screen awake during import — iOS throttles BLE when the screen locks,
        // causing mid-transfer failures on slow dive computers (e.g. Halcyon Symbios).
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif

        // Enable BLE-level logging for real-device debugging
        BLEPeripheralTransport.enableLogging = true

        // When a BLE-sourced fingerprint was supplied, libdivecomputer should stop
        // on its own before reaching already-imported dives, so consecutive skips
        // indicate a stale fingerprint — stop early rather than downloading ten
        // full dives just to discard them (PRO-70). Without a fingerprint (first
        // sync, forced full sync) or with a legacy one the device may not
        // recognise (e.g. Shearwater Cloud IDs), keep the wider window.
        let tracker = ImportProgressTracker(consecutiveSkipThreshold: syncFP?.source == .ble ? 3 : 10)

        // Dives are written on a separate serial queue so the libdivecomputer
        // callback returns immediately and the next dive request goes out while
        // the previous dive is being saved. Halcyon Symbios devices time out and
        // drop the link if the host goes quiet between dives (PRO-71).
        let persistence = DivePersistenceQueue(
            importService: importService,
            tracker: tracker
        ) { [weak self] parsed, outcome, error in
            if let error {
                let desc = error.localizedDescription
                importLog.error(
                    "Failed to save dive at \(parsed.startTimeUnix): \(desc, privacy: .public)"
                )
            }
            _ = outcome

            // Auto-stop after consecutive duplicates (threshold set above from
            // fingerprint provenance; only without an explicit cutoff). Evaluated
            // after each save. Saves lag the download, so dives already handed
            // to this queue — and the one libdivecomputer is fetching when it
            // next polls `onCancel` — are still processed; they are counted as
            // skipped, not lost.
            if tracker.shouldAutoStop && cutoffTime == nil {
                cancellation.set()
            }

            let s = tracker.saved
            let m = tracker.merged
            let k = tracker.skipped
            let f = tracker.failed
            Task { @MainActor [weak self] in
                var parts: [String] = []
                if s > 0 { parts.append("\(s) saved") }
                if m > 0 { parts.append("\(m) merged") }
                if k > 0 { parts.append("\(k) skipped") }
                if f > 0 { parts.append("\(f) failed") }
                let msg = parts.isEmpty
                    ? "Processing..."
                    : parts.joined(separator: ", ") + "..."
                self?.statusMessage = msg
            }
        }

        downloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Progress-aware retry: keep reconnecting as long as new dives are
            // being downloaded. Some devices (e.g. Halcyon Symbios) drop the BLE
            // session between dives, so each reconnect may yield only one more
            // dive. Give up after consecutive attempts with no new saves. Three
            // rather than two because the first session after connect has been
            // observed to fail before any dive is attempted (PRO-71).
            let maxNoProgress = 3
            var consecutiveNoProgress = 0
            var attempt = 0
            var currentTransport: TracingBLETransport = tracingTransport
            var currentLink = initialLink

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
                                cancellation.set()
                                return
                            }

                            // Hand off for persistence and return immediately so
                            // libdivecomputer can request the next dive. Save
                            // outcomes (including errors) are recorded by the
                            // queue's completion handler above.
                            persistence.enqueue(parsed, deviceId: device.id)
                        },
                        onProgress: { progress in
                            Task { @MainActor [weak self] in
                                self?.downloadProgress = (progress.currentDive, progress.totalDives)
                            }
                        },
                        onCancel: { cancellation.isSet }
                    )

                    // Success — wait for queued saves, then update device info
                    await persistence.drainAsync()
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
                    let failed = tracker.failed
                    let autoStopped = tracker.shouldAutoStop
                    // Successful sessions are traced too: a device that has
                    // silently served bad data looks like a clean completion.
                    self.writeTraceFile(
                        currentTransport, device: device, attempt: attempt,
                        reason: "completed (\(saved) new, \(merged) merged, \(skipped) skipped, "
                            + "\(failed) failed)",
                        link: currentLink
                    )
                    await MainActor.run {
                        // The download itself succeeded, but if every dive it
                        // delivered failed to save there is nothing to celebrate.
                        if failed > 0 && saved == 0 && merged == 0 {
                            let plural = failed == 1 ? "" : "s"
                            self.phase = .error(.downloadFailed(
                                "\(failed) dive\(plural) downloaded from \(device.displayName) "
                                    + "could not be saved."
                            ))
                            return
                        }
                        self.phase = .completed(ImportResult(
                            newDives: saved,
                            mergedDives: merged,
                            skippedDives: skipped,
                            deviceName: device.displayName,
                            autoStopped: autoStopped,
                            failedDives: failed
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
                        if failed > 0 {
                            let plural = failed == 1 ? "" : "s"
                            self.statusMessage += " \(failed) dive\(plural) could not be saved."
                        }
                    }
                    return

                } catch DiveComputerError.cancelled {
                    await persistence.drainAsync()
                    importLog.info("Import cancelled — dumping I/O trace")
                    currentTransport.dumpTrace()
                    self.writeTraceFile(
                        currentTransport, device: device, attempt: attempt,
                        reason: "cancelled", link: currentLink
                    )
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
                                autoStopped: autoStopped,
                                failedDives: tracker.failed
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
                    // Dives delivered before the failure may still be in the
                    // persistence queue; wait so progress accounting is accurate.
                    await persistence.drainAsync()
                    let newSaves = tracker.saved - savedBefore
                    let newMerges = tracker.merged - mergedBefore
                    let madeProgress = newSaves > 0 || newMerges > 0

                    let errDesc = error.localizedDescription
                    importLog.error(
                        "Attempt \(attempt) (\(newSaves) new, \(newMerges) merged): \(errDesc, privacy: .public)"
                    )
                    currentTransport.dumpTrace()
                    self.writeTraceFile(
                        currentTransport, device: device, attempt: attempt,
                        reason: errDesc, link: currentLink
                    )

                    let retryable = (error as? DiveComputerError)?.isRetryable ?? true
                    if !retryable {
                        // Non-retryable — report error with partial results
                        await self.finalizeOnError(
                            tracker: tracker, device: device, knownComputer: knownComputer,
                            error: error
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
                                tracker: tracker, device: device, knownComputer: knownComputer,
                                error: error
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
                              peripheral: peripheral,
                              delay: knownComputer?.transportQuirks.reconnectDelay ?? 2
                          ) else {
                        await self.finalizeOnReconnectFailure(
                            tracker: tracker, device: device
                        )
                        return
                    }
                    currentTransport = TracingBLETransport(wrapping: newTransport)
                    currentLink = newTransport.linkDescription
                    importLog.notice("Transport: \(currentLink, privacy: .public)")
                    // Only reset if user hasn't cancelled during reconnect
                    guard !Task.isCancelled else { continue }
                    cancellation.reset()
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
        cancellation.set()
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
        cancellation.set()
        downloadTask?.cancel()
        scanner.stopScanning()
        scanner.disconnect()
        connectionTimeoutTask?.cancel()
        phase = .idle
        statusMessage = ""
        downloadProgress = nil
        isNewDevice = false
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

    /// Directory where import transport traces are written.
    ///
    /// `Library/Application Support/ImportTraces` inside the app container:
    /// diagnostic data, not user documents, so it stays out of the Files app
    /// and is excluded from iCloud document sync. Retrieve with:
    /// `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer
    ///  --domain-identifier azlucis.Profundum
    ///  --source "Library/Application Support/ImportTraces" --destination .`
    nonisolated static var traceDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ImportTraces", isDirectory: true)
    }

    /// Persists the transport trace for an attempt (completed, failed or
    /// cancelled) so it can be pulled off the device without Console.app.
    /// Never throws; failures to write are logged and otherwise ignored.
    nonisolated private func writeTraceFile(
        _ transport: TracingBLETransport, device: Device, attempt: Int, reason: String,
        link: String
    ) {
        guard let dir = Self.traceDirectory else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let safeName = device.displayName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let url = dir.appendingPathComponent("\(stamp)_\(safeName)_attempt\(attempt).txt")
        let header = [
            "device: \(device.displayName) (\(device.model), sn \(device.serialNumber))",
            "firmware: \(device.firmwareVersion)",
            "attempt: \(attempt)",
            "reason: \(reason)",
            "link: \(link)",
            "",
        ]
        do {
            try transport.writeTrace(to: url, header: header)
            importLog.notice("Trace written to \(url.path, privacy: .public)")
            Self.pruneTraceFiles(in: dir, keeping: 30)
        } catch {
            let desc = error.localizedDescription
            importLog.error("Failed to write trace file: \(desc, privacy: .public)")
        }
    }

    /// Keeps only the newest `limit` trace files (names sort chronologically).
    nonisolated static func pruneTraceFiles(in dir: URL, keeping limit: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let sorted = names.filter { $0.hasSuffix(".txt") }.sorted()
        guard sorted.count > limit else { return }
        for name in sorted.prefix(sorted.count - limit) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Disconnects, waits for the device to reset, reconnects, and waits for
    /// a new BLE transport to become available.
    ///
    /// - Parameters:
    ///   - peripheral: The `CBPeripheral` to reconnect to.
    ///   - delay: Seconds to wait after disconnecting, giving the device time to
    ///     reset its BLE stack (and, for devices with a host-timeout state
    ///     machine, to let a wedged transfer expire).
    /// - Returns: The new transport, or `nil` if reconnection timed out.
    private func reconnect(
        peripheral: CBPeripheral, delay: TimeInterval
    ) async -> BLEPeripheralTransport? {
        await MainActor.run { scanner.disconnect() }

        importLog.info("Reconnecting in \(delay, privacy: .public)s")
        try? await Task.sleep(for: .seconds(delay))
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
        // Clean up so isConnecting doesn't stay stuck
        await MainActor.run { scanner.disconnect() }
        return nil
    }

    /// Shared cleanup for non-retryable errors or exhausted retries.
    /// Shows partial results if any dives were saved.
    private func finalizeOnError(
        tracker: ImportProgressTracker, device: Device, knownComputer: KnownDiveComputer?,
        error: Error
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
                    autoStopped: autoStopped,
                    failedDives: tracker.failed
                ))
                let total = saved + merged
                let plural = total == 1 ? "" : "s"
                self.statusMessage =
                    "Connection lost. \(total) dive\(plural) saved before the error."
            } else {
                var message = error.localizedDescription
                if knownComputer == .halcyonSymbios {
                    message += " The Symbios usually needs to be powered off and on "
                        + "before the next attempt."
                }
                self.phase = .error(.downloadFailed(message))
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
                        autoStopped: autoStopped,
                        failedDives: tracker.failed
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
                    autoStopped: autoStopped,
                    failedDives: tracker.failed
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
            isNewDevice = true
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
