import DivelogCore
import SwiftUI

/// Library section containing devices, sites, teammates, equipment, and formulas.
struct LibraryView: View {
    enum LibrarySection: String, CaseIterable, Identifiable {
        case devices = "Devices"
        case sites = "Sites"
        case teammates = "Teammates"
        case equipment = "Equipment"
        case formulas = "Formulas"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .devices: return "laptopcomputer"
            case .sites: return "mappin.and.ellipse"
            case .teammates: return "person.2"
            case .equipment: return "wrench.and.screwdriver"
            case .formulas: return "function"
            }
        }

        var description: String {
            switch self {
            case .devices: return "Dive computers and connected devices"
            case .sites: return "Dive sites and locations"
            case .teammates: return "Dive buddies and team members"
            case .equipment: return "Gear and equipment inventory"
            case .formulas: return "Custom calculated fields"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List(LibrarySection.allCases) { section in
                NavigationLink(destination: view(for: section)) {
                    HStack(spacing: 12) {
                        Image(systemName: section.systemImage)
                            .font(.title2)
                            .foregroundColor(.accentColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.rawValue)
                                .font(.headline)
                            Text(section.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Library")
        }
    }

    @ViewBuilder
    private func view(for section: LibrarySection) -> some View {
        switch section {
        case .devices:
            DeviceListView()
        case .sites:
            SiteListView()
        case .teammates:
            TeammateListView()
        case .equipment:
            EquipmentListView()
        case .formulas:
            FormulaListView()
        }
    }
}
