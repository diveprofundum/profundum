import Combine
import DivelogCore
import SwiftUI

@main
struct ProfundumApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(appState.colorScheme)
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var showClearDataConfirmation = false

    /// True if using in-memory database due to file system errorM
    @Published var isUsingInMemoryDatabase = false

    /// Error message if database initialization had issues
    @Published var databaseWarning: String?

    /// True if sample data has been loaded
    @Published var hasSampleData = false

    /// User settings (unit preferences, etc.)
    @Published var settings: DivelogCore.Settings = DivelogCore.Settings()

    let database: DivelogDatabase
    let diveService: DiveService
    let formulaService: FormulaService
    let sampleDataService: SampleDataService
    let importService: DiveComputerImportService
    let shearwaterImportService: ShearwaterCloudImportService

    var depthUnit: DepthUnit { settings.depthUnit }
    var temperatureUnit: TemperatureUnit { settings.temperatureUnit }
    var pressureUnit: PressureUnit { settings.pressureUnit }

    var colorScheme: ColorScheme? {
        switch settings.appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")

        // Use in-memory DB for UI testing, file-based otherwise
        var db: DivelogDatabase
        var usingInMemory = false
        var warning: String?

        if isUITesting {
            do {
                db = try DivelogDatabase(path: ":memory:")
                usingInMemory = true
            } catch {
                fatalError("Failed to initialize UI testing database: \(error)")
            }
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let dbPath = documents.appendingPathComponent("divelog.sqlite").path

            do {
                db = try DivelogDatabase(path: dbPath)
            } catch {
                warning = "Could not access database file. "
                    + "Using temporary in-memory storage. "
                    + "Your data will not be saved."
                usingInMemory = true

                do {
                    db = try DivelogDatabase(path: ":memory:")
                } catch {
                    fatalError("Failed to initialize even in-memory database: \(error)")
                }
            }
        }

        database = db
        diveService = DiveService(database: database)
        formulaService = FormulaService(database: database)
        sampleDataService = SampleDataService(database: database)
        importService = DiveComputerImportService(database: database)
        shearwaterImportService = ShearwaterCloudImportService(database: database)
        isUsingInMemoryDatabase = usingInMemory
        databaseWarning = warning

        // Seed sample data for UI tests
        if isUITesting {
            try? sampleDataService.loadSampleData()
            hasSampleData = true
        } else {
            hasSampleData = (try? sampleDataService.hasSampleData()) ?? false
        }

        // Load saved settings
        if let saved = try? diveService.getSettings() {
            settings = saved
        }
    }

    func updateSettings(_ newSettings: DivelogCore.Settings) {
        do {
            try diveService.saveSettings(newSettings)
            settings = newSettings
        } catch {
            print("Failed to save settings: \(error)")
        }
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
