import SwiftUI
import DivelogCore

@main
struct DivelogApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Dive...") {
                    appState.showNewDiveSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Import Dives...") {
                    appState.showImportPanel = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        #endif
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var showNewDiveSheet = false
    @Published var showImportPanel = false
    @Published var selectedDiveId: String?

    let database: DivelogDatabase
    let diveService: DiveService
    let formulaService: FormulaService

    init() {
        // Use a default path in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let divelogDir = appSupport.appendingPathComponent("Divelog", isDirectory: true)

        try? FileManager.default.createDirectory(at: divelogDir, withIntermediateDirectories: true)

        let dbPath = divelogDir.appendingPathComponent("divelog.sqlite").path

        do {
            database = try DivelogDatabase(path: dbPath)
            diveService = DiveService(database: database)
            formulaService = FormulaService(database: database)
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }
}
