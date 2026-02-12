import DivelogCore
import SwiftUI

struct NewDiveSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState

    @State private var devices: [Device] = []
    @State private var selectedDeviceId: String?

    @State private var startDate = Date()
    @State private var durationMinutes = 60
    @State private var maxDepthText = "30.0"
    @State private var avgDepthText = "18.0"
    @State private var bottomTimeMinutes = 50

    @State private var isCCR = false
    @State private var decoRequired = false
    @State private var cnsPercentText = "0"
    @State private var otuText = "0"

    // Site
    @State private var sites: [Site] = []
    @State private var selectedSiteId: String?
    @State private var isCreatingNewSite = false
    @State private var newSiteName = ""

    // Tags
    @State private var selectedDiveTypeTag: PredefinedDiveTag = .oc
    @State private var selectedActivityTags: Set<PredefinedDiveTag> = []
    @State private var customTags: [String] = []
    @State private var newCustomTag = ""
    @State private var savedCustomTags: [String] = []

    /// Custom tags from previous dives that aren't already added to this dive.
    private var unselectedCustomTags: [String] {
        savedCustomTags.filter { !customTags.contains($0) }
    }

    // Teammates
    @State private var teammates: [Teammate] = []
    @State private var selectedTeammateIds: Set<String> = []
    @State private var teammateSearchText = ""

    // Equipment
    @State private var equipment: [Equipment] = []
    @State private var selectedEquipmentIds: Set<String> = []
    @State private var equipmentSearchText = ""
    @State private var errorMessage: String?

    // Edit mode
    var editingDive: Dive?
    var editingTags: [String] = []
    var editingTeammateIds: [String] = []
    var editingEquipmentIds: [String] = []

    private var sheetTitle: String {
        editingDive != nil ? "Edit Dive" : "New Dive"
    }

    var body: some View {
        NavigationStack {
            Form {
                basicInfoSection
                siteSection
                depthTimeSection
                diveTypeSection
                exposureSection
                tagsSection
                teammatesSection
                equipmentSection
            }
            .formStyle(.grouped)
            .navigationTitle(sheetTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 500, idealWidth: 600, minHeight: 500)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveDive()
                    }
                    .disabled(selectedDeviceId == nil)
                    .accessibilityIdentifier("saveButton")
                }
            }
            .task {
                do {
                    devices = try appState.diveService.listDevices()
                    sites = try appState.diveService.listSites()
                    teammates = try appState.diveService.listTeammates()
                    equipment = try appState.diveService.listEquipment()
                    savedCustomTags = try appState.diveService.allCustomTags()
                } catch {
                    errorMessage = "Failed to load form data: \(error.localizedDescription)"
                }
            }
            .onAppear {
                if let dive = editingDive {
                    selectedDeviceId = dive.deviceId
                    // Timestamps are stored as local time in UTC epoch seconds.
                    // Shift so the DatePicker (which uses device timezone) shows the correct local time.
                    // Use the offset at the dive's time (not now) so DST transitions don't shift by 1h.
                    let approxDate = Date(timeIntervalSince1970: TimeInterval(dive.startTimeUnix))
                    let tzOffset = TimeInterval(TimeZone.current.secondsFromGMT(for: approxDate))
                    startDate = Date(timeIntervalSince1970: TimeInterval(dive.startTimeUnix) - tzOffset)
                    let totalSeconds = dive.endTimeUnix - dive.startTimeUnix
                    durationMinutes = Int(totalSeconds / 60)
                    let displayMaxDepth = UnitFormatter.depth(dive.maxDepthM, unit: appState.depthUnit)
                    let displayAvgDepth = UnitFormatter.depth(dive.avgDepthM, unit: appState.depthUnit)
                    maxDepthText = String(format: "%.1f", displayMaxDepth)
                    avgDepthText = String(format: "%.1f", displayAvgDepth)
                    bottomTimeMinutes = Int(dive.bottomTimeSec / 60)
                    isCCR = dive.isCcr
                    decoRequired = dive.decoRequired
                    cnsPercentText = String(format: "%.0f", dive.cnsPercent)
                    otuText = String(format: "%.0f", dive.otu)
                    selectedSiteId = dive.siteId

                    for tag in editingTags {
                        if let predefined = PredefinedDiveTag(fromTag: tag) {
                            if predefined.category == .diveType {
                                selectedDiveTypeTag = predefined
                            } else {
                                selectedActivityTags.insert(predefined)
                            }
                        } else {
                            // Handle legacy tags from before the taxonomy change
                            if tag == "oc_rec" {
                                selectedDiveTypeTag = .oc
                                selectedActivityTags.insert(.rec)
                            } else if tag == "oc_deco" {
                                selectedDiveTypeTag = .oc
                                selectedActivityTags.insert(.deco)
                            } else {
                                customTags.append(tag)
                            }
                        }
                    }

                    selectedTeammateIds = Set(editingTeammateIds)
                    selectedEquipmentIds = Set(editingEquipmentIds)
                } else {
                    // New dive: set initial tags from toggles
                    selectedDiveTypeTag = PredefinedDiveTag.diveTypeTag(isCcr: isCCR)
                    for tag in PredefinedDiveTag.autoActivityTags(isCcr: isCCR, decoRequired: decoRequired) {
                        selectedActivityTags.insert(tag)
                    }
                }
            }
            .onChange(of: isCCR) { _, newValue in
                let newTag = PredefinedDiveTag.diveTypeTag(isCcr: newValue)
                if selectedDiveTypeTag != newTag { selectedDiveTypeTag = newTag }
            }
            .onChange(of: decoRequired) { _, newValue in
                if newValue {
                    selectedActivityTags.remove(.rec)
                    selectedActivityTags.insert(.deco)
                } else {
                    selectedActivityTags.remove(.deco)
                }
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    private var basicInfoSection: some View {
        Section("Basic Info") {
            Picker("Device", selection: $selectedDeviceId) {
                Text("Select device").tag(nil as String?)
                ForEach(devices, id: \.id) { device in
                    Text(device.model).tag(device.id as String?)
                }
            }

            DatePicker("Start Time", selection: $startDate)

            Stepper("Duration: \(durationMinutes) min", value: $durationMinutes, in: 1...600)
        }
    }

    private var siteSection: some View {
        Section("Site") {
            if isCreatingNewSite {
                HStack {
                    TextField("New site name", text: $newSiteName)
                    Button("Add") {
                        addNewSite()
                    }
                    .disabled(newSiteName.isEmpty)
                    Button("Cancel") {
                        isCreatingNewSite = false
                        newSiteName = ""
                    }
                }
            } else {
                HStack {
                    Picker("Dive Site", selection: $selectedSiteId) {
                        Text("None").tag(nil as String?)
                        ForEach(sites, id: \.id) { site in
                            Text(site.name).tag(site.id as String?)
                        }
                    }
                    Button {
                        isCreatingNewSite = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var depthTimeSection: some View {
        Section("Depth & Time") {
            HStack {
                Text("Max Depth")
                Spacer()
                TextField("30.0", text: $maxDepthText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text(UnitFormatter.depthLabel(appState.depthUnit))
            }

            HStack {
                Text("Avg Depth")
                Spacer()
                TextField("18.0", text: $avgDepthText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text(UnitFormatter.depthLabel(appState.depthUnit))
            }

            Stepper("Bottom Time: \(bottomTimeMinutes) min", value: $bottomTimeMinutes, in: 1...600)
        }
    }

    private var diveTypeSection: some View {
        Section("Dive Type") {
            Toggle("CCR Dive", isOn: $isCCR)
            Toggle("Deco Required", isOn: $decoRequired)
        }
    }

    private var exposureSection: some View {
        Section("Exposure") {
            HStack {
                Text("CNS %")
                Spacer()
                TextField("0", text: $cnsPercentText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }

            HStack {
                Text("OTU")
                Spacer()
                TextField("0", text: $otuText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
        }
    }

    private var tagsSection: some View {
        Section("Tags") {
            // Breathing System (mutually exclusive)
            VStack(alignment: .leading, spacing: 4) {
                Text("Breathing System")
                    .font(.caption)
                    .foregroundColor(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                    ForEach(PredefinedDiveTag.diveTypeCases, id: \.self) { tag in
                        TagChipView(
                            tag: tag,
                            isSelected: selectedDiveTypeTag == tag
                        ) {
                            selectedDiveTypeTag = tag
                            isCCR = tag == .ccr
                        }
                    }
                }
            }

            // Activity tags (multi-select)
            VStack(alignment: .leading, spacing: 4) {
                Text("Activity")
                    .font(.caption)
                    .foregroundColor(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                    ForEach(PredefinedDiveTag.activityCases, id: \.self) { tag in
                        TagChipView(
                            tag: tag,
                            isSelected: selectedActivityTags.contains(tag)
                        ) {
                            if selectedActivityTags.contains(tag) {
                                selectedActivityTags.remove(tag)
                                if tag == .deco { decoRequired = false }
                            } else {
                                selectedActivityTags.insert(tag)
                                // Rec and deco are mutually exclusive
                                if tag == .deco {
                                    selectedActivityTags.remove(.rec)
                                    decoRequired = true
                                } else if tag == .rec {
                                    selectedActivityTags.remove(.deco)
                                    decoRequired = false
                                }
                            }
                        }
                    }
                }
            }

            // Recent custom tags as suggestion chips
            if !unselectedCustomTags.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Tags")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                        ForEach(unselectedCustomTags, id: \.self) { tag in
                            Button {
                                if !customTags.contains(tag) {
                                    customTags.append(tag)
                                }
                            } label: {
                                Text(tag)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.secondary.opacity(0.1))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                    )
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !customTags.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                    ForEach(customTags, id: \.self) { tag in
                        Button {
                            customTags.removeAll { $0 == tag }
                        } label: {
                            HStack(spacing: 4) {
                                Text(tag)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.secondary.opacity(0.3))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.secondary, lineWidth: 1)
                            )
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                TextField("Custom tag", text: $newCustomTag)
                    .onSubmit { addCustomTag() }
                Button("Add") {
                    addCustomTag()
                }
                .disabled(newCustomTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var selectedTeammates: [Teammate] {
        teammates.filter { selectedTeammateIds.contains($0.id) }
    }

    private var filteredUnselectedTeammates: [Teammate] {
        let unselected = teammates.filter { !selectedTeammateIds.contains($0.id) }
        if teammateSearchText.isEmpty { return [] }
        return unselected.filter {
            $0.displayName.localizedCaseInsensitiveContains(teammateSearchText)
        }
    }

    private var teammatesSection: some View {
        Section("Teammates") {
            // Selected teammates as removable chips
            if !selectedTeammates.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(selectedTeammates, id: \.id) { teammate in
                        Button {
                            selectedTeammateIds.remove(teammate.id)
                        } label: {
                            HStack(spacing: 4) {
                                Text(teammate.displayName)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.blue.opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.blue.opacity(0.4), lineWidth: 1)
                            )
                            .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Search field to find and add existing teammates
            TextField("Search teammates", text: $teammateSearchText)
            #if os(iOS)
                .textInputAutocapitalization(.words)
            #endif

            // Matching results
            ForEach(filteredUnselectedTeammates, id: \.id) { teammate in
                Button {
                    selectedTeammateIds.insert(teammate.id)
                    teammateSearchText = ""
                } label: {
                    HStack {
                        Image(systemName: "person")
                            .foregroundColor(.secondary)
                        Text(teammate.displayName)
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "plus.circle")
                            .foregroundColor(.blue)
                    }
                }
                .buttonStyle(.plain)
            }

            // Create new teammate inline
            if !teammateSearchText.trimmingCharacters(in: .whitespaces).isEmpty &&
                filteredUnselectedTeammates.isEmpty {
                Button {
                    addNewTeammate()
                } label: {
                    HStack {
                        Image(systemName: "person.badge.plus")
                            .foregroundColor(.blue)
                        Text("Add \"\(teammateSearchText.trimmingCharacters(in: .whitespaces))\"")
                            .foregroundColor(.blue)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var selectedEquipment: [Equipment] {
        equipment.filter { selectedEquipmentIds.contains($0.id) }
    }

    private var filteredUnselectedEquipment: [Equipment] {
        let unselected = equipment.filter { !selectedEquipmentIds.contains($0.id) }
        if equipmentSearchText.isEmpty { return [] }
        return unselected.filter {
            $0.name.localizedCaseInsensitiveContains(equipmentSearchText)
        }
    }

    private var equipmentSection: some View {
        Section("Equipment") {
            // Selected equipment as removable chips
            if !selectedEquipment.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(selectedEquipment, id: \.id) { item in
                        Button {
                            selectedEquipmentIds.remove(item.id)
                        } label: {
                            HStack(spacing: 4) {
                                Text(item.name)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.green.opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.green.opacity(0.4), lineWidth: 1)
                            )
                            .foregroundColor(.green)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Search field to find and add existing equipment
            TextField("Search equipment", text: $equipmentSearchText)

            // Matching results
            ForEach(filteredUnselectedEquipment, id: \.id) { item in
                Button {
                    selectedEquipmentIds.insert(item.id)
                    equipmentSearchText = ""
                } label: {
                    HStack {
                        Image(systemName: "wrench")
                            .foregroundColor(.secondary)
                        Text(item.name)
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "plus.circle")
                            .foregroundColor(.green)
                    }
                }
                .buttonStyle(.plain)
            }

            // Create new equipment inline
            if !equipmentSearchText.trimmingCharacters(in: .whitespaces).isEmpty &&
                filteredUnselectedEquipment.isEmpty {
                Button {
                    addNewEquipment()
                } label: {
                    HStack {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundColor(.green)
                        Text("Add \"\(equipmentSearchText.trimmingCharacters(in: .whitespaces))\"")
                            .foregroundColor(.green)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Inline creation actions

    private func addNewSite() {
        let name = newSiteName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let site = Site(name: name)
        do {
            try appState.diveService.saveSite(site, tags: [])
            sites.append(site)
            selectedSiteId = site.id
            newSiteName = ""
            isCreatingNewSite = false
        } catch {
            errorMessage = "Failed to create site: \(error.localizedDescription)"
        }
    }

    private func addCustomTag() {
        let tag = newCustomTag.trimmingCharacters(in: .whitespaces).lowercased()
        guard !tag.isEmpty else { return }
        if let predefined = PredefinedDiveTag(fromTag: tag) {
            if predefined.category == .diveType {
                selectedDiveTypeTag = predefined
                isCCR = predefined == .ccr
            } else {
                selectedActivityTags.insert(predefined)
            }
        } else if !customTags.contains(tag) {
            customTags.append(tag)
        }
        newCustomTag = ""
    }

    private func addNewTeammate() {
        let name = teammateSearchText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let teammate = Teammate(displayName: name)
        do {
            try appState.diveService.saveTeammate(teammate)
            teammates.append(teammate)
            selectedTeammateIds.insert(teammate.id)
            teammateSearchText = ""
        } catch {
            errorMessage = "Failed to create teammate: \(error.localizedDescription)"
        }
    }

    private func addNewEquipment() {
        let name = equipmentSearchText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let item = Equipment(name: name, kind: "Other")
        do {
            try appState.diveService.saveEquipment(item)
            equipment.append(item)
            selectedEquipmentIds.insert(item.id)
            equipmentSearchText = ""
        } catch {
            errorMessage = "Failed to create equipment: \(error.localizedDescription)"
        }
    }

    // MARK: - Save

    private func saveDive() {
        guard let deviceId = selectedDeviceId else { return }

        // Convert DatePicker's real-UTC Date back to our local-time-as-UTC convention.
        let tzOffset = Int64(TimeZone.current.secondsFromGMT(for: startDate))
        let startUnix = Int64(startDate.timeIntervalSince1970) + tzOffset
        let endUnix = startUnix + Int64(durationMinutes * 60)

        let maxDepthInput = Float(Double(maxDepthText) ?? 0)
        let avgDepthInput = Float(Double(avgDepthText) ?? 0)

        let dive = Dive(
            id: editingDive?.id ?? UUID().uuidString,
            deviceId: deviceId,
            startTimeUnix: startUnix,
            endTimeUnix: endUnix,
            maxDepthM: UnitFormatter.depthToMetric(maxDepthInput, from: appState.depthUnit),
            avgDepthM: UnitFormatter.depthToMetric(avgDepthInput, from: appState.depthUnit),
            bottomTimeSec: Int32(bottomTimeMinutes * 60),
            isCcr: isCCR,
            decoRequired: decoRequired,
            cnsPercent: Float(Double(cnsPercentText) ?? 0),
            otu: Float(Double(otuText) ?? 0),
            siteId: selectedSiteId,
            computerDiveNumber: editingDive?.computerDiveNumber,
            fingerprint: editingDive?.fingerprint
        )

        var allTags = [selectedDiveTypeTag.rawValue]
        allTags.append(contentsOf: selectedActivityTags.map(\.rawValue))
        allTags.append(contentsOf: customTags)

        do {
            try appState.diveService.saveDive(
                dive,
                tags: allTags,
                teammateIds: Array(selectedTeammateIds),
                equipmentIds: Array(selectedEquipmentIds)
            )
            dismiss()
        } catch {
            errorMessage = "Failed to save dive: \(error.localizedDescription)"
        }
    }
}

// MARK: - FlowLayout

/// Simple flow layout for wrapping tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + position.x,
                    y: bounds.minY + position.y
                ),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
