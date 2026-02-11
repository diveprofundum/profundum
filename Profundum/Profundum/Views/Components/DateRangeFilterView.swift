import SwiftUI

/// Quick date range presets for filtering.
enum DatePreset: String, CaseIterable {
    case lastWeek = "7 Days"
    case lastMonth = "30 Days"
    case last3Months = "3 Months"
    case lastYear = "Year"
    case allTime = "All Time"

    var dateRange: (start: Date?, end: Date?) {
        let calendar = Calendar.current
        let now = Date()

        switch self {
        case .lastWeek:
            return (calendar.date(byAdding: .day, value: -7, to: now), now)
        case .lastMonth:
            return (calendar.date(byAdding: .day, value: -30, to: now), now)
        case .last3Months:
            return (calendar.date(byAdding: .month, value: -3, to: now), now)
        case .lastYear:
            return (calendar.date(byAdding: .year, value: -1, to: now), now)
        case .allTime:
            return (nil, nil)
        }
    }
}

/// A popover view for filtering dives by date range with presets and graphical pickers.
struct DateRangeFilterView: View {
    @Binding var startDate: Date?
    @Binding var endDate: Date?
    let onApply: () -> Void

    @State private var localStartDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var localEndDate: Date = Date()
    @State private var selectedPreset: DatePreset?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Quick presets
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Filter")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(DatePreset.allCases, id: \.self) { preset in
                            Button(preset.rawValue) {
                                applyPreset(preset)
                            }
                            .buttonStyle(.bordered)
                            .tint(selectedPreset == preset ? .accentColor : nil)
                            .controlSize(.small)
                        }
                    }
                }
            }

            Divider()

            // Custom date range
            VStack(alignment: .leading, spacing: 12) {
                Text("Custom Range")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("From")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        DatePicker(
                            "",
                            selection: $localStartDate,
                            in: ...localEndDate,
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .onChange(of: localStartDate) { _, _ in
                            selectedPreset = nil
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("To")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        DatePicker(
                            "",
                            selection: $localEndDate,
                            in: localStartDate...,
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .onChange(of: localEndDate) { _, _ in
                            selectedPreset = nil
                        }
                    }
                }

                Button("Apply Custom Range") {
                    startDate = localStartDate
                    endDate = localEndDate
                    onApply()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding()
        .onAppear {
            if let start = startDate {
                localStartDate = start
            }
            if let end = endDate {
                localEndDate = end
            }
            selectedPreset = matchPreset()
        }
    }

    private func applyPreset(_ preset: DatePreset) {
        selectedPreset = preset
        let range = preset.dateRange
        startDate = range.start
        endDate = range.end

        if let start = range.start {
            localStartDate = start
        }
        if let end = range.end {
            localEndDate = end
        }

        onApply()
    }

    private func matchPreset() -> DatePreset? {
        guard let start = startDate else {
            if endDate == nil {
                return .allTime
            }
            return nil
        }

        let calendar = Calendar.current
        let now = Date()

        for preset in DatePreset.allCases {
            if preset == .allTime { continue }
            let range = preset.dateRange
            if let presetStart = range.start,
               calendar.isDate(start, inSameDayAs: presetStart),
               endDate != nil,
               calendar.isDate(endDate!, inSameDayAs: now) {
                return preset
            }
        }

        return nil
    }
}

/// Button that shows the date filter state and opens popover.
struct DateFilterButton: View {
    @Binding var startDate: Date?
    @Binding var endDate: Date?
    @Binding var showPopover: Bool
    let onApply: () -> Void

    private var hasDateFilter: Bool {
        startDate != nil || endDate != nil
    }

    private var filterSummary: String? {
        let formatter = DateFormatter()
        formatter.dateStyle = .short

        if let start = startDate, let end = endDate {
            return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
        } else if let start = startDate {
            return "From \(formatter.string(from: start))"
        } else if let end = endDate {
            return "Until \(formatter.string(from: end))"
        }
        return nil
    }

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: hasDateFilter ? "calendar.badge.checkmark" : "calendar")
                if let summary = filterSummary {
                    Text(summary)
                        .font(.caption)
                }
            }
            .foregroundColor(hasDateFilter ? .accentColor : .secondary)
        }
        .popover(isPresented: $showPopover) {
            DateRangeFilterView(
                startDate: $startDate,
                endDate: $endDate,
                onApply: {
                    showPopover = false
                    onApply()
                }
            )
        }
    }
}
