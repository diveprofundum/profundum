import SwiftUI
import DivelogCore

struct ContentView: View {
    @EnvironmentObject var appState: AppState

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

            TabView(selection: $appState.selectedTab) {
                DiveListView()
                    .tabItem {
                        Label("Dives", systemImage: "waveform.path")
                    }
                    .tag(AppState.Tab.dives)

                DeviceListView()
                    .tabItem {
                        Label("Devices", systemImage: "laptopcomputer")
                    }
                    .tag(AppState.Tab.devices)

                SiteListView()
                    .tabItem {
                        Label("Sites", systemImage: "mappin.and.ellipse")
                    }
                    .tag(AppState.Tab.sites)

                BuddyListView()
                    .tabItem {
                        Label("Buddies", systemImage: "person.2")
                    }
                    .tag(AppState.Tab.buddies)

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(AppState.Tab.settings)
            }
        }
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
            Text("This will permanently delete all dives, devices, sites, buddies, and equipment. This cannot be undone.")
        }
    }
}
