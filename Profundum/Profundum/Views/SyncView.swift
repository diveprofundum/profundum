import CoreBluetooth
import DivelogCore
import SwiftUI
import UniformTypeIdentifiers

struct SyncView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var session = ImportSession()
    @State private var showingFileImporter = false
    @State private var fileImportResult: ShearwaterCloudImportResult?
    @State private var fileImportError: String?
    @State private var isImportingFile = false
    @State private var fileImportProgress: (current: Int, total: Int)?
    @State private var forceFullSync = false

    var body: some View {
        NavigationStack {
            Group {
                if isImportingFile {
                    fileImportingView
                } else if let result = fileImportResult {
                    fileImportCompletedView(result)
                } else if let error = fileImportError {
                    fileImportErrorView(error)
                } else {
                    switch session.phase {
                    case .idle:
                        idleView
                    case .scanning:
                        scanningView
                    case .connecting(let device):
                        connectingView(device)
                    case .paired(let device):
                        pairedView(device)
                    case .importing:
                        importingView
                    case .completed(let result):
                        completedView(result)
                    case .error(let error):
                        errorView(error)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .navigationTitle("Sync")
            .task {
                session.configure(
                    diveService: appState.diveService,
                    importService: appState.importService
                )
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.database, .data],
                onCompletion: handleFileImport
            )
        }
    }

    // MARK: - Phase Views

    private var idleView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text("Dive Computer Sync")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Connect to your BLE-enabled dive computer to download dive data.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            bleStatusView

            Button {
                session.startScan()
            } label: {
                Label("Scan for Dive Computers", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(session.scanner.managerState != .poweredOn)
            .accessibilityIdentifier("scanButton")

            Button {
                showingFileImporter = true
            } label: {
                Label("Import from Shearwater Cloud", systemImage: "doc.badge.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("fileImportButton")

            Spacer()
        }
    }

    private var scanningView: some View {
        VStack(spacing: 16) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning for dive computers...")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    session.cancelScan()
                }
            }

            if session.scanner.discoveredDevices.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Searching...")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Make sure your dive computer is awake and in range.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
            } else {
                List(session.scanner.discoveredDevices) { device in
                    Button {
                        session.selectDevice(device)
                    } label: {
                        DiscoveredDeviceRow(device: device)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private func connectingView(_ device: DiscoveredDevice) -> some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView()
                .controlSize(.large)

            Text("Connecting to \(device.name ?? "device")...")
                .font(.headline)

            if let vendor = device.knownComputer?.vendorName {
                Text(vendor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button("Cancel") {
                session.cancelScan()
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }

    private func pairedView(_ device: Device) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Connected")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 4) {
                Text(device.model)
                    .font(.headline)
                if let bleUuid = device.bleUuid {
                    Text(bleUuid)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Toggle("Full Sync", isOn: $forceFullSync)
                .font(.subheadline)
                .frame(maxWidth: 250)
                .accessibilityHint("Downloads all dives instead of only new ones")

            HStack(spacing: 12) {
                Button {
                    session.startImport(forceFullSync: forceFullSync)
                } label: {
                    Label("Import Dives", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Done") {
                    session.reset()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Spacer()
        }
    }

    private var importingView: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView()
                .controlSize(.large)

            Text("Downloading Dives...")
                .font(.headline)

            Text(session.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let progress = session.downloadProgress {
                if let total = progress.total {
                    ProgressView(value: Double(progress.current), total: Double(total))
                        .frame(maxWidth: 250)
                }
                Text("Dive \(progress.current)\(progress.total.map { " of \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Button("Cancel") {
                session.cancelImport()
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }

    private func completedView(_ result: ImportResult) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Sync Complete")
                .font(.title2)
                .fontWeight(.semibold)

            if !session.statusMessage.isEmpty {
                Text(session.statusMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)
            }

            if result.newDives > 0 || result.skippedDives > 0 {
                VStack(spacing: 8) {
                    if result.newDives > 0 {
                        let plural = result.newDives == 1 ? "" : "s"
                        Label(
                            "\(result.newDives) new dive\(plural) imported",
                            systemImage: "plus.circle"
                        )
                    }
                    if result.skippedDives > 0 {
                        let plural = result.skippedDives == 1 ? "" : "s"
                        Label(
                            "\(result.skippedDives) duplicate\(plural) skipped",
                            systemImage: "arrow.right.circle"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }

            HStack(spacing: 12) {
                Button("Done") {
                    forceFullSync = false
                    session.reset()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Scan Again") {
                    forceFullSync = false
                    session.reset()
                    session.startScan()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Spacer()
        }
    }

    private func errorView(_ error: ImportError) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)

            Text("Error")
                .font(.title2)
                .fontWeight(.semibold)

            Text(error.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            if error == .bluetoothOff || error == .bluetoothUnauthorized {
                bleSettingsLink
            }

            HStack(spacing: 12) {
                Button("Retry") {
                    session.reset()
                    session.startScan()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Cancel") {
                    session.reset()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Spacer()
        }
    }

    // MARK: - File Import Views

    private var fileImportingView: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView()
                .controlSize(.large)

            Text("Importing from Shearwater Cloud...")
                .font(.headline)

            if let progress = fileImportProgress {
                ProgressView(value: Double(progress.current), total: Double(progress.total))
                    .frame(maxWidth: 250)
                Text("Dive \(progress.current) of \(progress.total)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
    }

    private func fileImportCompletedView(_ result: ShearwaterCloudImportResult) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Import Complete")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 8) {
                if result.divesImported > 0 {
                    let p = result.divesImported == 1 ? "" : "s"
                    Label(
                        "\(result.divesImported) dive\(p) imported",
                        systemImage: "plus.circle"
                    )
                }
                if result.divesSkipped > 0 {
                    let p = result.divesSkipped == 1 ? "" : "s"
                    Label(
                        "\(result.divesSkipped) duplicate\(p) skipped",
                        systemImage: "arrow.right.circle"
                    )
                    .foregroundStyle(.secondary)
                }
                if result.devicesCreated > 0 {
                    let p = result.devicesCreated == 1 ? "" : "s"
                    Label(
                        "\(result.devicesCreated) device\(p) created",
                        systemImage: "cpu"
                    )
                    .foregroundStyle(.secondary)
                }
                if result.sitesCreated > 0 {
                    let p = result.sitesCreated == 1 ? "" : "s"
                    Label(
                        "\(result.sitesCreated) site\(p) created",
                        systemImage: "mappin"
                    )
                    .foregroundStyle(.secondary)
                }
                if result.teammatesCreated > 0 {
                    let p = result.teammatesCreated == 1 ? "" : "s"
                    Label(
                        "\(result.teammatesCreated) teammate\(p) created",
                        systemImage: "person.2"
                    )
                    .foregroundStyle(.secondary)
                }
                if result.divesMerged > 0 {
                    let p = result.divesMerged == 1 ? "" : "s"
                    Label(
                        "\(result.divesMerged) dive\(p) merged (multi-computer)",
                        systemImage: "arrow.triangle.merge"
                    )
                    .foregroundStyle(.secondary)
                }
                #if DEBUG
                Label("PPO2 samples: \(result.samplesWithPpo2)", systemImage: "waveform.path.ecg")
                    .foregroundStyle(.tertiary)
                #endif
            }
            .font(.subheadline)

            Button("Done") {
                fileImportResult = nil
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
    }

    private func fileImportErrorView(_ error: String) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)

            Text("Import Failed")
                .font(.title2)
                .fontWeight(.semibold)

            Text(error)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            HStack(spacing: 12) {
                Button("Try Again") {
                    fileImportError = nil
                    showingFileImporter = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Cancel") {
                    fileImportError = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Spacer()
        }
    }

    // MARK: - File Import Handler

    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            isImportingFile = true
            fileImportProgress = nil
            fileImportResult = nil
            fileImportError = nil

            let service = appState.shearwaterImportService
            let path = url.path

            Task.detached(priority: .userInitiated) {
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let importResult = try service.importFromFile(at: path) { current, total in
                        Task { @MainActor in
                            fileImportProgress = (current, total)
                        }
                    }
                    await MainActor.run {
                        isImportingFile = false
                        fileImportResult = importResult
                    }
                } catch {
                    await MainActor.run {
                        isImportingFile = false
                        fileImportError = error.localizedDescription
                    }
                }
            }

        case .failure(let error):
            fileImportError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var bleStatusView: some View {
        switch session.scanner.managerState {
        case .poweredOff:
            Label("Bluetooth is off", systemImage: "bolt.slash.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        case .unauthorized:
            Label("Bluetooth access not authorized", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.red)
        case .unsupported:
            Label("Bluetooth is not supported on this device", systemImage: "xmark.circle")
                .font(.callout)
                .foregroundStyle(.red)
        case .poweredOn:
            Label("Bluetooth ready", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.green)
        default:
            Label("Initializing Bluetooth...", systemImage: "ellipsis.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bleSettingsLink: some View {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            Link("Open Settings", destination: url)
                .buttonStyle(.bordered)
        }
        #else
        Text("Enable Bluetooth in System Settings > Bluetooth")
            .font(.caption)
            .foregroundStyle(.secondary)
        #endif
    }
}

// MARK: - Discovered Device Row

private struct DiscoveredDeviceRow: View {
    let device: DiscoveredDevice

    var body: some View {
        HStack(spacing: 12) {
            signalIcon
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name ?? "Unknown Device")
                    .font(.body)
                    .fontWeight(.medium)
                if let vendor = device.knownComputer?.vendorName {
                    Text(vendor)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var signalIcon: some View {
        let bars: Int = {
            if device.rssi > -50 { return 3 }
            if device.rssi > -70 { return 2 }
            return 1
        }()

        let name: String = {
            switch bars {
            case 3: return "wifi"
            case 2: return "wifi"
            default: return "wifi"
            }
        }()

        Image(systemName: name)
            .foregroundStyle(bars >= 3 ? .green : bars >= 2 ? .orange : .red)
            .font(.body)
    }
}
