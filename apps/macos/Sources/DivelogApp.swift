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

            CommandGroup(after: .importExport) {
                Divider()

                Button("Load Sample Data") {
                    appState.loadSampleData()
                }
                .disabled(appState.hasSampleData)

                Button("Clear All Data...") {
                    appState.showClearDataConfirmation = true
                }
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
    @Published var showClearDataConfirmation = false
    @Published var selectedDiveId: String?

    /// True if using in-memory database due to file system error
    @Published var isUsingInMemoryDatabase = false

    /// Error message if database initialization had issues
    @Published var databaseWarning: String?

    /// True if sample data has been loaded
    @Published var hasSampleData = false

    let database: DivelogDatabase
    let diveService: DiveService
    let formulaService: FormulaService
    let sampleDataService: SampleDataService

    init() {
        // Use a default path in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let divelogDir = appSupport.appendingPathComponent("Divelog", isDirectory: true)

        try? FileManager.default.createDirectory(at: divelogDir, withIntermediateDirectories: true)

        let dbPath = divelogDir.appendingPathComponent("divelog.sqlite").path

        // Try file-based database first, fall back to in-memory if it fails
        var db: DivelogDatabase
        var usingInMemory = false
        var warning: String? = nil

        do {
            db = try DivelogDatabase(path: dbPath)
        } catch {
            // Fall back to in-memory database
            warning = "Could not access database file. Using temporary in-memory storage. Your data will not be saved. Error: \(error.localizedDescription)"
            usingInMemory = true

            do {
                db = try DivelogDatabase(path: ":memory:")
            } catch {
                // This should never happen - in-memory DB should always work
                fatalError("Failed to initialize even in-memory database: \(error)")
            }
        }

        database = db
        diveService = DiveService(database: database)
        formulaService = FormulaService(database: database)
        sampleDataService = SampleDataService(database: database)
        isUsingInMemoryDatabase = usingInMemory
        databaseWarning = warning

        // Check if sample data exists
        hasSampleData = (try? sampleDataService.hasSampleData()) ?? false
    }

    func loadSampleData() {
        do {
            try sampleDataService.loadSampleData()
            hasSampleData = true
        } catch {
            print("Failed to load sample data: \(error)")
        }
    }

    func clearAllData() {
        do {
            try sampleDataService.clearAllData()
            hasSampleData = false
        } catch {
            print("Failed to clear data: \(error)")
        }
    }
}
