import SwiftUI
import UniformTypeIdentifiers
import DivelogCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var settings: DivelogCore.Settings?
    @State private var timeFormat: TimeFormat = .hhMmSs
    @State private var appearanceMode: AppearanceMode = .system
    @State private var depthUnit: DepthUnit = .meters
    @State private var temperatureUnit: TemperatureUnit = .celsius
    @State private var pressureUnit: PressureUnit = .bar
    @State private var showExportSheet = false
    @State private var showImportPicker = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Display") {
                    Picker("Appearance", selection: $appearanceMode) {
                        Text("System").tag(AppearanceMode.system)
                        Text("Light").tag(AppearanceMode.light)
                        Text("Dark").tag(AppearanceMode.dark)
                    }
                    .onChange(of: appearanceMode) { _, _ in saveSettings() }

                    Picker("Time Format", selection: $timeFormat) {
                        Text("HH:MM:SS").tag(TimeFormat.hhMmSs)
                        Text("MM:SS").tag(TimeFormat.mmSs)
                    }
                    .onChange(of: timeFormat) { _, newValue in
                        saveSettings()
                    }
                }

                Section("Units") {
                    Picker("Depth", selection: $depthUnit) {
                        Text("Meters").tag(DepthUnit.meters)
                        Text("Feet").tag(DepthUnit.feet)
                    }
                    .onChange(of: depthUnit) { _, _ in saveSettings() }

                    Picker("Temperature", selection: $temperatureUnit) {
                        Text("Celsius").tag(TemperatureUnit.celsius)
                        Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
                    }
                    .onChange(of: temperatureUnit) { _, _ in saveSettings() }

                    Picker("Pressure", selection: $pressureUnit) {
                        Text("Bar").tag(PressureUnit.bar)
                        Text("PSI").tag(PressureUnit.psi)
                    }
                    .onChange(of: pressureUnit) { _, _ in saveSettings() }
                }

                Section("Data") {
                    Button("Export All Data") {
                        showExportSheet = true
                    }

                    Button("Import Data") {
                        showImportPicker = true
                    }
                }

                Section("Sample Data") {
                    Button("Load Sample Data") {
                        appState.loadSampleData()
                    }
                    .disabled(appState.hasSampleData)

                    Button("Clear All Data", role: .destructive) {
                        appState.showClearDataConfirmation = true
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Build", value: "1")
                }

                #if DEBUG
                Section("Debug") {
                    Button("Test Error Alert") {
                        errorMessage = "This is a test error alert. Error handling is working correctly."
                    }
                }
                #endif
            }
            .navigationTitle("Settings")
            .task {
                await loadSettings()
            }
            .sheet(isPresented: $showExportSheet) {
                ExportSheet()
            }
            .fileImporter(
                isPresented: $showImportPicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func loadSettings() async {
        let current = appState.settings
        settings = current
        timeFormat = current.timeFormat
        appearanceMode = current.appearanceMode
        depthUnit = current.depthUnit
        temperatureUnit = current.temperatureUnit
        pressureUnit = current.pressureUnit
    }

    private func saveSettings() {
        let newSettings = DivelogCore.Settings(
            timeFormat: timeFormat,
            depthUnit: depthUnit,
            temperatureUnit: temperatureUnit,
            pressureUnit: pressureUnit,
            appearanceMode: appearanceMode
        )
        appState.updateSettings(newSettings)
        settings = newSettings
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                let exportService = ExportService(database: appState.database)
                _ = try exportService.importJSON(data)
            } catch {
                errorMessage = "Import failed: \(error.localizedDescription)"
            }

        case .failure(let error):
            errorMessage = "File picker failed: \(error.localizedDescription)"
        }
    }
}

enum ExportFormat: String, CaseIterable {
    case json = "JSON"
    case csv = "CSV"
}

struct ExportSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var exportFileURL: URL?
    @State private var errorMessage: String?
    @State private var selectedFormat: ExportFormat = .json

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)

                Text("Export Dive Data")
                    .font(.title2)

                Text(selectedFormat == .json
                    ? "Export all dives, devices, sites, and teammates to a JSON file."
                    : "Export a summary of all dives to a CSV spreadsheet.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                Picker("Format", selection: $selectedFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 40)
                .onChange(of: selectedFormat) { _, _ in
                    exportFileURL = nil
                }

                Button("Export") {
                    generateExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(exportFileURL != nil)

                if let exportFileURL {
                    ShareLink(item: exportFileURL) {
                        Label("Share Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .navigationTitle("Export")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 400, idealWidth: 500, minHeight: 350)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func generateExport() {
        do {
            let exportService = ExportService(database: appState.database)
            let ext = selectedFormat == .json ? "json" : "csv"
            let data: Data
            switch selectedFormat {
            case .json:
                data = try exportService.exportAll()
            case .csv:
                data = try exportService.exportDivesAsCSV(ids: [])
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("divelog-export.\(ext)")
            try data.write(to: url)
            exportFileURL = url
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}