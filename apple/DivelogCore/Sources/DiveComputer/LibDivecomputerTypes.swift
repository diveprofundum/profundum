import Foundation

#if canImport(LibDivecomputerFFI)
import LibDivecomputerFFI

/// RAII wrapper around `dc_context_t*` with automatic cleanup.
public final class DCContext {
    public let pointer: OpaquePointer

    public init() throws {
        var ctx: OpaquePointer?
        let status = dc_context_new(&ctx)
        guard status == DC_STATUS_SUCCESS, let ptr = ctx else {
            throw DiveComputerError.libdivecomputer(
                status: status.rawValue,
                message: dcStatusMessage(status)
            )
        }
        self.pointer = ptr
    }

    deinit {
        dc_context_free(pointer)
    }
}

/// Maps a `dc_status_t` value to a human-readable string.
public func dcStatusMessage(_ status: dc_status_t) -> String {
    switch status {
    case DC_STATUS_SUCCESS:       return "Success"
    case DC_STATUS_DONE:          return "Done"
    case DC_STATUS_UNSUPPORTED:   return "Unsupported"
    case DC_STATUS_INVALIDARGS:   return "Invalid arguments"
    case DC_STATUS_NOMEMORY:      return "Out of memory"
    case DC_STATUS_NODEVICE:      return "No device"
    case DC_STATUS_NOACCESS:      return "Access denied"
    case DC_STATUS_IO:            return "I/O error"
    case DC_STATUS_TIMEOUT:       return "Timeout"
    case DC_STATUS_PROTOCOL:      return "Protocol error"
    case DC_STATUS_DATAFORMAT:    return "Data format error"
    case DC_STATUS_CANCELLED:     return "Cancelled"
    default:                      return "Unknown error (\(status.rawValue))"
    }
}

#endif
