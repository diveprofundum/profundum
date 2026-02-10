import Foundation

/// Progress of a dive download operation.
public struct DownloadProgress: Sendable {
    public let currentDive: Int
    public let totalDives: Int?

    public init(currentDive: Int, totalDives: Int? = nil) {
        self.currentDive = currentDive
        self.totalDives = totalDives
    }
}

/// Result of a completed dive download.
public struct DownloadResult: Sendable {
    public let totalDives: Int
    public let serialNumber: String?
    public let firmwareVersion: String?

    public init(totalDives: Int, serialNumber: String? = nil, firmwareVersion: String? = nil) {
        self.totalDives = totalDives
        self.serialNumber = serialNumber
        self.firmwareVersion = firmwareVersion
    }
}

/// Protocol for downloading dives from a dive computer.
///
/// The concrete implementation (`DiveDownloadService`) uses libdivecomputer
/// and is only available when `LibDivecomputerFFI` is linked. Code that needs
/// to attempt a download should accept an optional `DiveDownloader?` and
/// surface a clear error when `nil`.
///
/// Each parsed dive is delivered via `onDive` as it arrives, so the caller
/// can persist it immediately. This keeps memory flat and makes cancellation
/// or disconnect preserve all progress saved so far.
public protocol DiveDownloader: Sendable {
    func download(
        transport: BLETransport,
        deviceName: String,
        lastFingerprint: Data?,
        onDive: @escaping (ParsedDive) -> Void,
        onProgress: @escaping (DownloadProgress) -> Void,
        onCancel: @escaping () -> Bool
    ) throws -> DownloadResult
}

/// Returns a `DiveDownloader` if libdivecomputer is linked, otherwise `nil`.
public func makeDiveDownloader() -> DiveDownloader? {
    #if canImport(LibDivecomputerFFI)
    return DiveDownloadService()
    #else
    return nil
    #endif
}

// MARK: - libdivecomputer Implementation

#if canImport(LibDivecomputerFFI)
import LibDivecomputerFFI

/// Orchestrates the libdivecomputer download sequence:
/// `dc_context_new -> IOStreamBridge.open -> dc_device_open -> dc_device_foreach -> parse`.
///
/// All operations run on a dedicated serial queue, never the Swift cooperative thread pool.
public final class DiveDownloadService: DiveDownloader, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.divelog.download", qos: .userInitiated)

    public init() {}

    public func download(
        transport: BLETransport,
        deviceName: String,
        lastFingerprint: Data?,
        onDive: @escaping (ParsedDive) -> Void,
        onProgress: @escaping (DownloadProgress) -> Void,
        onCancel: @escaping () -> Bool
    ) throws -> DownloadResult {
        try queue.sync {
            try performDownload(
                transport: transport,
                deviceName: deviceName,
                lastFingerprint: lastFingerprint,
                onDive: onDive,
                onProgress: onProgress,
                onCancel: onCancel
            )
        }
    }

    // MARK: - Private

    private func performDownload(
        transport: BLETransport,
        deviceName: String,
        lastFingerprint: Data?,
        onDive: @escaping (ParsedDive) -> Void,
        onProgress: @escaping (DownloadProgress) -> Void,
        onCancel: @escaping () -> Bool
    ) throws -> DownloadResult {
        // 1. Create context
        let context = try DCContext()

        // 2. Find descriptor by matching BLE device name
        let descriptor = try findDescriptor(deviceName: deviceName, context: context.pointer)
        defer { dc_descriptor_free(descriptor) }

        // 3. Open iostream via BLE transport bridge
        let bridge = IOStreamBridge(transport: transport)
        let iostream = try bridge.open(context: context.pointer)

        // 4. Open device
        var device: OpaquePointer?
        let openStatus = dc_device_open(&device, context.pointer, descriptor, iostream)
        guard openStatus == DC_STATUS_SUCCESS, let dev = device else {
            throw DiveComputerError.libdivecomputer(
                status: openStatus.rawValue,
                message: dcStatusMessage(openStatus)
            )
        }
        defer { dc_device_close(dev) }

        // 5. Set fingerprint for incremental sync
        if let fp = lastFingerprint {
            fp.withUnsafeBytes { ptr in
                _ = dc_device_set_fingerprint(
                    dev,
                    ptr.bindMemory(to: UInt8.self).baseAddress,
                    UInt32(fp.count)
                )
            }
        }

        // 6. Register for device info events (serial, firmware)
        var devInfo = DevInfoContext()
        withUnsafeMutablePointer(to: &devInfo) { ptr in
            _ = dc_device_set_events(dev, UInt32(DC_EVENT_DEVINFO.rawValue), devInfoCallback, ptr)
        }

        // 7. Enumerate dives
        var callbackContext = DiveCallbackContext(
            device: dev,
            onDive: onDive,
            onProgress: onProgress,
            onCancel: onCancel
        )

        let foreachStatus = withUnsafeMutablePointer(to: &callbackContext) { ptr in
            dc_device_foreach(dev, diveCallback, ptr)
        }

        // Check for cancellation
        if onCancel() {
            throw DiveComputerError.cancelled
        }

        if foreachStatus != DC_STATUS_SUCCESS && foreachStatus != DC_STATUS_DONE {
            throw DiveComputerError.libdivecomputer(
                status: foreachStatus.rawValue,
                message: dcStatusMessage(foreachStatus)
            )
        }

        return DownloadResult(
            totalDives: callbackContext.diveCount,
            serialNumber: devInfo.serialNumber,
            firmwareVersion: devInfo.firmwareVersion
        )
    }

    /// Finds the libdivecomputer descriptor matching the BLE device name.
    private func findDescriptor(deviceName: String, context: OpaquePointer) throws -> OpaquePointer {
        var iterator: OpaquePointer?
        guard dc_descriptor_iterator_new(&iterator, context) == DC_STATUS_SUCCESS,
              let iter = iterator else {
            throw DiveComputerError.unsupportedDevice
        }
        defer { dc_iterator_free(iter) }

        var descriptor: OpaquePointer?
        while dc_iterator_next(iter, &descriptor) == DC_STATUS_SUCCESS {
            guard let desc = descriptor else { continue }
            // dc_descriptor_filter checks if this descriptor matches the BLE device name
            let matches = deviceName.withCString { nameCStr in
                dc_descriptor_filter(desc, DC_TRANSPORT_BLE, nameCStr)
            }
            if matches != 0 {
                return desc
            }
            dc_descriptor_free(desc)
        }

        throw DiveComputerError.unsupportedDevice
    }
}

// MARK: - Device Info Callback

private struct DevInfoContext {
    var serialNumber: String?
    var firmwareVersion: String?
}

private func devInfoCallback(
    _ device: OpaquePointer?,
    _ event: dc_event_type_t,
    _ data: UnsafeRawPointer?,
    _ userdata: UnsafeMutableRawPointer?
) {
    guard event == DC_EVENT_DEVINFO, let data, let userdata else { return }
    let info = data.assumingMemoryBound(to: dc_event_devinfo_t.self).pointee
    let ctx = userdata.assumingMemoryBound(to: DevInfoContext.self)

    ctx.pointee.serialNumber = String(format: "%08X", info.serial)

    let major = (info.firmware >> 16) & 0xFF
    let minor = (info.firmware >> 8) & 0xFF
    let patch = info.firmware & 0xFF
    ctx.pointee.firmwareVersion = "\(major).\(minor).\(patch)"
}

// MARK: - Dive Callback

/// Context passed through the C callback.
private struct DiveCallbackContext {
    let device: OpaquePointer
    let onDive: (ParsedDive) -> Void
    let onProgress: (DownloadProgress) -> Void
    let onCancel: () -> Bool
    var diveCount: Int = 0
}

/// C callback invoked by `dc_device_foreach` for each dive.
private func diveCallback(
    _ data: UnsafePointer<UInt8>?,
    _ size: UInt32,
    _ fingerprint: UnsafePointer<UInt8>?,
    _ fpSize: UInt32,
    _ userdata: UnsafeMutableRawPointer?
) -> Int32 {
    guard let userdata else { return 0 }
    let ctx = userdata.assumingMemoryBound(to: DiveCallbackContext.self)

    // Check cancellation
    if ctx.pointee.onCancel() {
        return 0  // Returning 0 stops enumeration
    }

    ctx.pointee.diveCount += 1
    ctx.pointee.onProgress(DownloadProgress(
        currentDive: ctx.pointee.diveCount,
        totalDives: nil
    ))

    guard let data, size > 0 else { return 1 }

    // Extract fingerprint
    let fp: Data? = {
        guard let fingerprint, fpSize > 0 else { return nil }
        return Data(bytes: fingerprint, count: Int(fpSize))
    }()

    // Parse dive data and deliver immediately
    if let parsed = parseDiveData(
        device: ctx.pointee.device,
        data: data,
        size: size,
        fingerprint: fp
    ) {
        ctx.pointee.onDive(parsed)
    }

    return 1  // Continue enumeration
}

/// Parses a single dive's raw data into a `ParsedDive`.
private func parseDiveData(
    device: OpaquePointer,
    data: UnsafePointer<UInt8>,
    size: UInt32,
    fingerprint: Data?
) -> ParsedDive? {
    // dc_parser_new takes the data directly (no separate set_data call)
    var parser: OpaquePointer?
    let status = dc_parser_new(&parser, device, data, Int(size))
    guard status == DC_STATUS_SUCCESS, let p = parser else { return nil }
    defer { dc_parser_destroy(p) }

    // Extract datetime
    var datetime = dc_datetime_t()
    let dtStatus = dc_parser_get_datetime(p, &datetime)
    let startTimeUnix: Int64 = {
        guard dtStatus == DC_STATUS_SUCCESS else {
            return Int64(Date().timeIntervalSince1970)
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = Int(datetime.year)
        components.month = Int(datetime.month)
        components.day = Int(datetime.day)
        components.hour = Int(datetime.hour)
        components.minute = Int(datetime.minute)
        components.second = Int(datetime.second)
        return Int64(cal.date(from: components)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)
    }()

    // Extract max depth
    var maxDepth: Double = 0
    dc_parser_get_field(p, DC_FIELD_MAXDEPTH, 0, &maxDepth)

    // Extract avg depth
    var avgDepth: Double = 0
    dc_parser_get_field(p, DC_FIELD_AVGDEPTH, 0, &avgDepth)

    // Extract dive time
    var diveTime: UInt32 = 0
    dc_parser_get_field(p, DC_FIELD_DIVETIME, 0, &diveTime)

    // Extract dive mode to determine CCR
    var diveMode: dc_divemode_t = DC_DIVEMODE_OC
    dc_parser_get_field(p, DC_FIELD_DIVEMODE, 0, &diveMode)
    let isCcr = diveMode == DC_DIVEMODE_CCR || diveMode == DC_DIVEMODE_SCR

    // Parse samples
    var sampleContext = SampleCallbackContext()
    withUnsafeMutablePointer(to: &sampleContext) { ptr in
        _ = dc_parser_samples_foreach(p, sampleCallback, ptr)
    }

    // Commit the final in-progress sample
    if sampleContext.currentTime > 0 || !sampleContext.samples.isEmpty {
        sampleContext.samples.append(ParsedSample(
            tSec: sampleContext.currentTime,
            depthM: sampleContext.currentDepth,
            tempC: sampleContext.currentTemp,
            setpointPpo2: sampleContext.currentSetpoint,
            ceilingM: sampleContext.currentCeiling,
            gf99: sampleContext.currentGf99
        ))
    }

    let endTimeUnix = startTimeUnix + Int64(diveTime)

    return ParsedDive(
        startTimeUnix: startTimeUnix,
        endTimeUnix: endTimeUnix,
        maxDepthM: Float(maxDepth),
        avgDepthM: Float(avgDepth),
        bottomTimeSec: Int32(diveTime),
        isCcr: isCcr,
        decoRequired: sampleContext.maxCeiling > 0,
        fingerprint: fingerprint,
        samples: sampleContext.samples
    )
}

// MARK: - Sample Callback

private struct SampleCallbackContext {
    var samples: [ParsedSample] = []
    var currentTime: Int32 = 0
    var currentDepth: Float = 0
    var currentTemp: Float = 0
    var currentSetpoint: Float?
    var currentCeiling: Float?
    var currentGf99: Float?
    var maxCeiling: Float = 0
}

/// C callback invoked by `dc_parser_samples_foreach` for each sample field.
/// The `value` parameter is a pointer to a `dc_sample_value_t` union.
private func sampleCallback(
    _ type: dc_sample_type_t,
    _ value: UnsafePointer<dc_sample_value_t>?,
    _ userdata: UnsafeMutableRawPointer?
) {
    guard let userdata, let value else { return }
    let ctx = userdata.assumingMemoryBound(to: SampleCallbackContext.self)
    let v = value.pointee

    switch type {
    case DC_SAMPLE_TIME:
        // Commit previous sample if we have data
        if ctx.pointee.currentTime > 0 || !ctx.pointee.samples.isEmpty {
            let sample = ParsedSample(
                tSec: ctx.pointee.currentTime,
                depthM: ctx.pointee.currentDepth,
                tempC: ctx.pointee.currentTemp,
                setpointPpo2: ctx.pointee.currentSetpoint,
                ceilingM: ctx.pointee.currentCeiling,
                gf99: ctx.pointee.currentGf99
            )
            ctx.pointee.samples.append(sample)
        }
        ctx.pointee.currentTime = Int32(v.time)
        ctx.pointee.currentSetpoint = nil
        ctx.pointee.currentCeiling = nil
        ctx.pointee.currentGf99 = nil

    case DC_SAMPLE_DEPTH:
        ctx.pointee.currentDepth = Float(v.depth)

    case DC_SAMPLE_TEMPERATURE:
        ctx.pointee.currentTemp = Float(v.temperature)

    case DC_SAMPLE_SETPOINT:
        ctx.pointee.currentSetpoint = Float(v.setpoint)

    case DC_SAMPLE_DECO:
        let deco = v.deco
        ctx.pointee.currentCeiling = Float(deco.depth)
        if Float(deco.depth) > ctx.pointee.maxCeiling {
            ctx.pointee.maxCeiling = Float(deco.depth)
        }

    default:
        break
    }
}

#endif
