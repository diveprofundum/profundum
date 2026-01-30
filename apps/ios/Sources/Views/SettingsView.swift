import SwiftUI
import DivelogCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var settings: DivelogCore.Settings?
    @State private var timeFormat: TimeFormat = .hhMmSs
    @State private var showExportSheet = false
    @State private var showImportPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section("Display") {
                    Picker("Time Format", selection: $timeFormat) {
                        Text("HH:MM:SS").tag(TimeFormat.hhMmSs)
                        Text("MM:SS").tag(TimeFormat.mmSs)
                    }
                    .onChange(of: timeFormat) { _, newValue in
                        saveSettings()
                    }
                }

                Section("Data") {
                    Button("Export All Data") {
                        showExportSheet = true
                    }

                    Button("Import Data") {
                        showImportPicker = true
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
        do {
            if let loaded = try appState.diveService.getSettings() {
                settings = loaded
                timeFormat = loaded.timeFormat
            }
        } catch {
            print("Failed to load settings: \(error)")
        }
    }

    private func saveSettings() {
        let newSettings = DivelogCore.Settings(timeFormat: timeFormat)

        do {
            try appState.diveService.saveSettings(newSettings)
            settings = newSettings
        } catch {
            print("Failed to save settings: \(error)")
        }
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

                Text("Export all your dives, devices, sites, and buddies to a JSON file.")
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