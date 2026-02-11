import DivelogCore
import SwiftUI

/// A chip-style button for filtering by dive type (CCR, OC Deco, OC Rec).
struct DiveTypeChipView: View {
    let filter: DiveTypeFilter
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(filter.displayName)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isSelected ? filter.color.opacity(0.3) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? filter.color : Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .foregroundColor(isSelected ? filter.color : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.displayName) filter")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A chip-style button for filtering by predefined tags.
struct TagChipView: View {
    let tag: PredefinedDiveTag
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(tag.displayName)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isSelected ? tag.color.opacity(0.3) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? tag.color : Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .foregroundColor(isSelected ? tag.color : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tag.displayName) filter")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A badge for displaying a tag (non-interactive).
struct TagBadge: View {
    let tag: PredefinedDiveTag

    var body: some View {
        Text(tag.displayName)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tag.color.opacity(0.2))
            .foregroundColor(tag.color)
            .cornerRadius(6)
    }
}

/// A badge for displaying a custom (non-predefined) tag.
struct CustomTagBadge: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.2))
            .foregroundColor(.secondary)
            .cornerRadius(6)
    }
}
