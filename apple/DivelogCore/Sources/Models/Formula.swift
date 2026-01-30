import Foundation
import GRDB

/// A user-defined formula for calculated fields.
public struct Formula: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var expression: String
    public var description: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        expression: String,
        description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.expression = expression
        self.description = description
    }
}

// MARK: - GRDB Conformance

extension Formula: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "formulas"
}

/// A computed value from a formula for a specific dive.
public struct CalculatedField: Equatable, Sendable {
    public var formulaId: String
    public var diveId: String
    public var value: Double

    public init(formulaId: String, diveId: String, value: Double) {
        self.formulaId = formulaId
        self.diveId = diveId
        self.value = value
    }
}

extension CalculatedField: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "calculated_fields"

    enum CodingKeys: String, CodingKey {
        case formulaId = "formula_id"
        case diveId = "dive_id"
        case value
    }
}
