import SwiftUI
import DivelogCore

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
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
}
