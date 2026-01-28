# BLE Adapter Interfaces (Draft)

## Kotlin (conceptual)
```kotlin
sealed class BleError {
    object PermissionDenied : BleError()
    object BluetoothOff : BleError()
    object DeviceNotFound : BleError()
    object ConnectionFailed : BleError()
    object GattError : BleError()
    object ChecksumMismatch : BleError()
    object Timeout : BleError()
    object Cancelled : BleError()
    object Unknown : BleError()
}

data class BleDeviceInfo(
    val id: String,
    val name: String,
    val rssi: Short,
)

data class BleLogHeader(
    val id: String,
    val startTimeUnix: Long,
    val durationSec: Int,
    val maxDepthM: Float,
)

data class BleChunk(
    val offset: Int,
    val data: ByteArray,
    val crc: Int?
)

interface BleSession

interface BleAdapter {
    fun scan(timeoutMs: Int): Result<List<BleDeviceInfo>>
    fun connect(deviceId: String): Result<BleSession>
    fun disconnect(session: BleSession): Result<Unit>

    fun listLogs(session: BleSession): Result<List<BleLogHeader>>
    fun downloadLog(
        session: BleSession,
        logId: String,
        resumeOffset: Int? = null,
    ): Result<List<BleChunk>>
    fun cancel(session: BleSession): Result<Unit>
}
```

## Swift (conceptual)
```swift
enum BleError: Error {
    case permissionDenied
    case bluetoothOff
    case deviceNotFound
    case connectionFailed
    case gattError
    case checksumMismatch
    case timeout
    case cancelled
    case unknown
}

struct BleDeviceInfo {
    let id: String
    let name: String
    let rssi: Int16
}

struct BleLogHeader {
    let id: String
    let startTimeUnix: Int64
    let durationSec: Int32
    let maxDepthM: Float
}

struct BleChunk {
    let offset: UInt32
    let data: [UInt8]
    let crc: UInt32?
}

protocol BleSession {}

protocol BleAdapter {
    func scan(timeoutMs: UInt32) -> Result<[BleDeviceInfo], BleError>
    func connect(deviceId: String) -> Result<BleSession, BleError>
    func disconnect(session: BleSession) -> Result<Void, BleError>

    func listLogs(session: BleSession) -> Result<[BleLogHeader], BleError>
    func downloadLog(
        session: BleSession,
        logId: String,
        resumeOffset: UInt32?
    ) -> Result<[BleChunk], BleError>
    func cancel(session: BleSession) -> Result<Void, BleError>
}
```
