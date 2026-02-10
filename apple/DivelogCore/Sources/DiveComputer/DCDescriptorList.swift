import Foundation

#if canImport(LibDivecomputerFFI)
import LibDivecomputerFFI

/// A dive computer model supported by libdivecomputer.
public struct SupportedDiveComputer: Sendable {
    public let vendor: String
    public let product: String
    public let family: dc_family_t
    public let model: UInt32
    public let transportMask: UInt32

    /// Whether this device supports BLE transport.
    public var supportsBLE: Bool {
        transportMask & UInt32(DC_TRANSPORT_BLE.rawValue) != 0
    }
}

/// Enumerates all libdivecomputer descriptors that support BLE.
public func listBLESupportedComputers() -> [SupportedDiveComputer] {
    var result: [SupportedDiveComputer] = []

    var iterator: OpaquePointer?
    guard dc_descriptor_iterator_new(&iterator, nil) == DC_STATUS_SUCCESS, let iter = iterator else {
        return result
    }
    defer { dc_iterator_free(iter) }

    var descriptor: OpaquePointer?
    while dc_iterator_next(iter, &descriptor) == DC_STATUS_SUCCESS {
        guard let desc = descriptor else { continue }
        defer { dc_descriptor_free(desc) }

        let transport = dc_descriptor_get_transports(desc)
        guard transport & UInt32(DC_TRANSPORT_BLE.rawValue) != 0 else { continue }

        let vendor = String(cString: dc_descriptor_get_vendor(desc))
        let product = String(cString: dc_descriptor_get_product(desc))
        let family = dc_descriptor_get_type(desc)
        let model = dc_descriptor_get_model(desc)

        result.append(SupportedDiveComputer(
            vendor: vendor,
            product: product,
            family: family,
            model: model,
            transportMask: transport
        ))
    }

    return result
}

#endif
