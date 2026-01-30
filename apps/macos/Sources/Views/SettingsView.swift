import SwiftUI
import DivelogCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var settings: DivelogCore.Settings?
    @State private var timeFormat: TimeFormat = .hhMmSs

    var body: some View {
        TabView {
            displayTab
                .tabItem {
                    Label("Display", systemImage: "display")
                }

            dataTab
                .tabItem {
                    Label("Data", systemImage: "externaldrive")
                }
        }
        .frame(width: 450, height: 250)
        .task {
            await loadSettings()
        }
    }

    private var displayTab: some View {
        Form {
            Picker("Time Format", selection: $timeFormat) {
                Text("HH:MM:SS").tag(TimeFormat.hhMmSs)
                Text("MM:SS").tag(TimeFormat.mmSs)
            }
            .onChange(of: timeFormat) { _, newValue in
                saveSettings()
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var dataTab: some View {
        Form {
            Section("Database") {
                LabeledContent("Location") {
                    Text(getDatabasePath())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Reveal in Finder") {
                    let url = URL(fileURLWithPath: getDatabasePath())
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                }
            }

            Section("Export") {
                Button("Export All Data...") {
                    exportData()
                }

                Button("Import Data...") {
                    importData()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func getDatabasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Divelog/divelog.sqlite").path
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

    private func exportData() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "divelog-export.json"

        if panel.runModal() == .OK, let url = panel.url {
            let exportService = ExportService(database: appState.database)
            do {
                let data = try exportService.exportAll()
                try data.write(to: url)
            } catch {
                print("Export failed: \(error)")
            }
        }
    }

    private func importData() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            let exportService = ExportService(database: appState.database)
            do {
                let data = try Data(contentsOf: url)
                _ = try exportService.importJSON(data)
            } catch {
                print("Import failed: \(error)")
            }
        }
    }
}
