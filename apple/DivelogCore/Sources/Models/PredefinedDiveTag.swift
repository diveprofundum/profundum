import Foundation
import SwiftUI

/// Dive type filters based on dive properties (computed, not stored as tags).
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

/// Predefined dive tags for environment/activity filtering.
/// These tags are stored in the dive_tags table.
public enum PredefinedDiveTag: String, CaseIterable, Sendable {
    case cave
    case wreck
    case reef
    case night
    case shore
    case deep
    case training
    case technical

    /// Display name for UI presentation.
    public var displayName: String {
        switch self {
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
