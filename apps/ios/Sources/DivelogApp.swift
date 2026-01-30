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

    enum Tab {
        case dives, devices, sites, buddies, settings
    }

    let database: DivelogDatabase
    let diveService: DiveService
    let formulaService: FormulaService

    init() {
        // Use a default path in Documents
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbPath = documents.appendingPathComponent("divelog.sqlite").path

        do {
            database = try DivelogDatabase(path: dbPath)
            diveService = DiveService(database: database)
            formulaService = FormulaService(database: database)
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }
}
