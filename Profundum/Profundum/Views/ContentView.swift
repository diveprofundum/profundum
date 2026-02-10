import SwiftUI
import DivelogCore

enum AppTab: String, CaseIterable {
    case log = "Log"
    case library = "Library"
    case sync = "Sync"
    case settings = "Settings"

    var systemImage: String {
        switch self {
        case .log: return "waveform.path"
        case .library: return "tray.full"
        case .sync: return "arrow.triangle.2.circlepath"
        case .settings: return "gear"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: AppTab = .log

    var body: some View {
        VStack(spacing: 0) {
            // Warning banner for in-memory database
            if appState.isUsingInMemoryDatabase, appState.databaseWarning != nil {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(appState.databaseWarning ?? "Using temporary storage.")
                        .font(.caption)
                    Spacer()
                    Button {
                        appState.databaseWarning = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.15))
            }

            TabView(selection: $selectedTab) {
                Tab(AppTab.log.rawValue, systemImage: AppTab.log.systemImage, value: .log) {
                    DiveListView()
                }

                Tab(AppTab.library.rawValue, systemImage: AppTab.library.systemImage, value: .library) {
                    LibraryView()
                }

                Tab(AppTab.sync.rawValue, systemImage: AppTab.sync.systemImage, value: .sync) {
                    SyncView()
                }

                Tab(AppTab.settings.rawValue, systemImage: AppTab.settings.systemImage, value: .settings) {
                    SettingsView()
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 600)
        #endif
        .confirmationDialog(
            "Clear All Data",
            isPresented: $appState.showClearDataConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Data", role: .destructive) {
                appState.clearAllData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all dives, devices, sites, teammates, and equipment. This cannot be undone.")
        }
    }
}
