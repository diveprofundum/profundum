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
        VStack(spacing: 0) {
            // Warning banner for in-memory database
            if appState.isUsingInMemoryDatabase {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(appState.databaseWarning ?? "Using temporary storage. Data will not be saved.")
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        appState.databaseWarning = nil
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.15))
            }

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
        }
        .frame(minWidth: 800, minHeight: 500)
        .sheet(isPresented: $appState.showNewDiveSheet) {
            NewDiveSheet()
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
