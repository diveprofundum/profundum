# UniFFI BLE Callback Examples (Draft)

These snippets show how a platform implementation can provide a BLE adapter to the Rust core via UniFFI.

## Kotlin (conceptual)
```kotlin
class AndroidBleSession : BleSession

class AndroidBleAdapter : BleAdapter {
    override fun scan(timeoutMs: Int): Result<List<BleDeviceInfo>> {
        // bridge to Android BLE stack
        return Result.success(listOf())
    }

    override fun connect(deviceId: String): Result<BleSession> {
        return Result.success(AndroidBleSession())
    }

    override fun disconnect(session: BleSession): Result<Unit> {
        return Result.success(Unit)
    }

    override fun listLogs(session: BleSession): Result<List<BleLogHeader>> {
        return Result.success(listOf())
    }

    override fun downloadLog(
        session: BleSession,
        logId: String,
        resumeOffset: Int?
    ): Result<List<BleChunk>> {
        return Result.success(listOf())
    }

    override fun cancel(session: BleSession): Result<Unit> {
        return Result.success(Unit)
    }
}

// Example: pass adapter to core (placeholder API)
val adapter = AndroidBleAdapter()
// divelogCore.setBleAdapter(adapter)
```

## Swift (conceptual)
```swift
final class AppleBleSession: BleSession {}

final class AppleBleAdapter: BleAdapter {
    func scan(timeoutMs: UInt32) -> Result<[BleDeviceInfo], BleError> {
        return .success([])
    }

    func connect(deviceId: String) -> Result<BleSession, BleError> {
        return .success(AppleBleSession())
    }

    func disconnect(session: BleSession) -> Result<Void, BleError> {
        return .success(())
    }

    func listLogs(session: BleSession) -> Result<[BleLogHeader], BleError> {
        return .success([])
    }

    func downloadLog(
        session: BleSession,
        logId: String,
        resumeOffset: UInt32?
    ) -> Result<[BleChunk], BleError> {
        return .success([])
    }

    func cancel(session: BleSession) -> Result<Void, BleError> {
        return .success(())
    }
}

let adapter = AppleBleAdapter()
// divelogCore.setBleAdapter(adapter)
```
