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
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var selectedTab: Tab = .dives
    @Published var showClearDataConfirmation = false

    /// True if using in-memory database due to file system error
    @Published var isUsingInMemoryDatabase = false

    /// Error message if database initialization had issues
    @Published var databaseWarning: String?

    /// True if sample data has been loaded
    @Published var hasSampleData = false

    enum Tab {
        case dives, devices, sites, buddies, settings
    }

    let database: DivelogDatabase
    let diveService: DiveService
    let formulaService: FormulaService
    let sampleDataService: SampleDataService

    init() {
        // Use a default path in Documents
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbPath = documents.appendingPathComponent("divelog.sqlite").path

        // Try file-based database first, fall back to in-memory if it fails
        var db: DivelogDatabase
        var usingInMemory = false
        var warning: String? = nil

        do {
            db = try DivelogDatabase(path: dbPath)
        } catch {
            // Fall back to in-memory database
            warning = "Could not access database file. Using temporary in-memory storage. Your data will not be saved."
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
