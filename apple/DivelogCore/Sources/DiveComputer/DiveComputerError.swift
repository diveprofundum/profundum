import Foundation

/// Errors that can occur during dive computer communication and import.
public enum DiveComputerError: Error, Equatable, Sendable {
    /// An error from libdivecomputer with a status code and message.
    case libdivecomputer(status: Int32, message: String)
    /// The BLE operation timed out.
    case timeout
    /// The BLE connection was lost.
    case disconnected
    /// The connected device is not supported.
    case unsupportedDevice
    /// The dive has already been imported (fingerprint match).
    case duplicateDive
    /// The user cancelled the operation.
    case cancelled
}

extension DiveComputerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .libdivecomputer(let status, let message):
            return "Dive computer error (status \(status)): \(message)"
        case .timeout:
            return "Communication with the dive computer timed out."
        case .disconnected:
            return "The dive computer disconnected."
        case .unsupportedDevice:
            return "This dive computer model is not supported."
        case .duplicateDive:
            return "This dive has already been imported."
        case .cancelled:
            return "The operation was cancelled."
        }
    }
}
