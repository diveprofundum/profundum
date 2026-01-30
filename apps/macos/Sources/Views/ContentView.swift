import SwiftUI
import DivelogCore

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedSidebarItem: SidebarItem? = .dives

    enum SidebarItem: String, CaseIterable, Identifiable {
        case dives = "Dives"
        case devices = "Devices"
        case sites = "Sites"
        case buddies = "Buddies"
        case equipment = "Equipment"
        case formulas = "Formulas"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .dives: return "waveform.path"
            case .devices: return "laptopcomputer"
            case .sites: return "mappin.and.ellipse"
            case .buddies: return "person.2"
            case .equipment: return "wrench.and.screwdriver"
            case .formulas: return "function"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedSidebarItem) { item in
                Label(item.rawValue, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationTitle("Divelog")
            .frame(minWidth: 180)
        } detail: {
            switch selectedSidebarItem {
            case .dives:
                DiveListView()
            case .devices:
                DeviceListView()
            case .sites:
                SiteListView()
            case .buddies:
                BuddyListView()
            case .equipment:
                EquipmentListView()
            case .formulas:
                FormulaListView()
            case .none:
                Text("Select an item from the sidebar")
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .sheet(isPresented: $appState.showNewDiveSheet) {
            NewDiveSheet()
        }
    }
}
