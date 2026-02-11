import Foundation
import SwiftUI

/// Dive type filters based on dive properties (computed, not stored as tags).
/// Used in the list view filter bar to filter by breathing system.
public enum DiveTypeFilter: String, CaseIterable, Sendable {
    case ccr
    case oc

    /// Display name for UI presentation.
    public var displayName: String {
        switch self {
        case .ccr: return "CCR"
        case .oc: return "OC"
        }
    }

    /// Color for UI presentation.
    public var color: Color {
        switch self {
        case .ccr: return .blue
        case .oc: return .green
        }
    }

    /// Check if a dive matches this filter.
    public func matches(dive: Dive) -> Bool {
        switch self {
        case .ccr:
            return dive.isCcr
        case .oc:
            return !dive.isCcr
        }
    }
}

/// Predefined dive tags stored in the dive_tags table.
/// Includes both breathing-system tags (mutually exclusive) and activity/environment tags.
public enum PredefinedDiveTag: String, CaseIterable, Sendable {
    // Breathing system tags (mutually exclusive)
    case oc
    case ccr

    // Activity / environment tags
    case rec
    case deco
    case cave
    case wreck
    case reef
    case night
    case shore
    case deep
    case training
    case technical

    /// Tag category for UI grouping.
    public enum Category: Equatable, Sendable {
        case diveType
        case activity
    }

    /// The category this tag belongs to.
    public var category: Category {
        switch self {
        case .oc, .ccr:
            return .diveType
        case .rec, .deco, .cave, .wreck, .reef, .night, .shore, .deep, .training, .technical:
            return .activity
        }
    }

    /// All dive-type (breathing system) tags.
    public static let diveTypeCases: [PredefinedDiveTag] =
        allCases.filter { $0.category == .diveType }

    /// All activity/environment tags.
    public static let activityCases: [PredefinedDiveTag] =
        allCases.filter { $0.category == .activity }

    /// Returns the appropriate breathing-system tag for a dive's properties.
    public static func diveTypeTag(isCcr: Bool) -> PredefinedDiveTag {
        isCcr ? .ccr : .oc
    }

    /// Returns the activity tags to auto-apply based on dive properties.
    public static func autoActivityTags(decoRequired: Bool) -> [PredefinedDiveTag] {
        [decoRequired ? .deco : .rec]
    }

    /// Display name for UI presentation.
    public var displayName: String {
        switch self {
        case .oc: return "OC"
        case .ccr: return "CCR"
        case .rec: return "Rec"
        case .deco: return "Deco"
        case .cave: return "Cave"
        case .wreck: return "Wreck"
        case .reef: return "Reef"
        case .night: return "Night"
        case .shore: return "Shore"
        case .deep: return "Deep"
        case .training: return "Training"
        case .technical: return "Technical"
        }
    }

    /// Color for UI presentation.
    public var color: Color {
        switch self {
        case .oc: return .green
        case .ccr: return .blue
        case .rec: return .mint
        case .deco: return .orange
        case .cave: return .brown
        case .wreck: return .gray
        case .reef: return .cyan
        case .night: return .indigo
        case .shore: return .teal
        case .deep: return .purple
        case .training: return .yellow
        case .technical: return .pink
        }
    }

    /// Initialize from a raw tag string if it matches a predefined tag.
    public init?(fromTag tag: String) {
        if let match = PredefinedDiveTag(rawValue: tag) {
            self = match
        } else {
            return nil
        }
    }
}
