import Foundation
import SwiftUI

/// Dive type filters based on dive properties (computed, not stored as tags).
/// NOTE: Display names and colors parallel PredefinedDiveTag's dive-type cases.
/// If a new dive type is added, update both enums.
public enum DiveTypeFilter: String, CaseIterable, Sendable {
    case ccr
    case ocDeco = "oc_deco"
    case ocRec = "oc_rec"

    /// Display name for UI presentation.
    public var displayName: String {
        switch self {
        case .ccr: return "CCR"
        case .ocDeco: return "OC Deco"
        case .ocRec: return "OC Rec"
        }
    }

    /// Color for UI presentation.
    public var color: Color {
        switch self {
        case .ccr: return .blue
        case .ocDeco: return .orange
        case .ocRec: return .green
        }
    }

    /// Check if a dive matches this filter.
    public func matches(dive: Dive) -> Bool {
        switch self {
        case .ccr:
            return dive.isCcr
        case .ocDeco:
            return !dive.isCcr && dive.decoRequired
        case .ocRec:
            return !dive.isCcr && !dive.decoRequired
        }
    }
}

/// Predefined dive tags stored in the dive_tags table.
/// Includes both dive-type tags and activity/environment tags.
public enum PredefinedDiveTag: String, CaseIterable, Sendable {
    // Dive type tags (mutually exclusive)
    case ocRec = "oc_rec"
    case ccr
    case ocDeco = "oc_deco"

    // Activity / environment tags
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
        case .ocRec, .ccr, .ocDeco:
            return .diveType
        case .cave, .wreck, .reef, .night, .shore, .deep, .training, .technical:
            return .activity
        }
    }

    /// All dive-type tags.
    public static let diveTypeCases: [PredefinedDiveTag] =
        allCases.filter { $0.category == .diveType }

    /// All activity/environment tags.
    public static let activityCases: [PredefinedDiveTag] =
        allCases.filter { $0.category == .activity }

    /// Returns the appropriate dive-type tag for a dive's properties.
    public static func diveTypeTag(isCcr: Bool, decoRequired: Bool) -> PredefinedDiveTag {
        if isCcr {
            return .ccr
        } else if decoRequired {
            return .ocDeco
        } else {
            return .ocRec
        }
    }

    /// Display name for UI presentation.
    public var displayName: String {
        switch self {
        case .ocRec: return "OC Rec"
        case .ccr: return "CCR"
        case .ocDeco: return "OC Deco"
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
        case .ocRec: return .green
        case .ccr: return .blue
        case .ocDeco: return .orange
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
