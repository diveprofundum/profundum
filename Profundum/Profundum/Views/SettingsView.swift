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
                print("Import failed: \(error)")
            }

        case .failure(let error):
            print("File picker failed: \(error)")
        }
    }
}

struct ExportSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var exportData: Data?
    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)

                Text("Export Dive Data")
                    .font(.title2)

                Text("Export all your dives, devices, sites, and teammates to a JSON file.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                Button("Export") {
                    generateExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(exportData != nil)

                if exportData != nil {
                    ShareLink(item: exportData!, preview: SharePreview("Divelog Export", image: Image(systemName: "doc.text"))) {
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
            .frame(minWidth: 400, idealWidth: 500, minHeight: 300)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func generateExport() {
        do {
            let exportService = ExportService(database: appState.database)
            exportData = try exportService.exportAll()
        } catch {
            print("Export failed: \(error)")
        }
    }
}