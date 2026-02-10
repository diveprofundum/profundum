// DivelogCore - Swift storage and compute layer for the Divelog application
//
// Architecture:
// - Swift (GRDB) owns all storage and domain models
// - Rust provides stateless compute for formulas and metrics
// - UniFFI bridges Swift ↔ Rust at runtime

// Re-export all public types for convenience

// Models
@_exported import struct Foundation.UUID
public typealias DivelogDevice = Device
public typealias DivelogSite = Site
public typealias DivelogTeammate = Teammate
public typealias DivelogEquipment = Equipment
public typealias DivelogDive = Dive
public typealias DivelogDiveSample = DiveSample
public typealias DivelogSegment = Segment
public typealias DivelogFormula = Formula
public typealias DivelogSettings = Settings
