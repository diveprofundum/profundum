# BLE Adapter API Contract (Draft)

## Goals
- Provide a consistent BLE interface across all platforms.
- Keep platform BLE details out of the Rust core.
- Support resume/retry and robust error reporting.

## Core concepts
- `BleAdapter`: platform bridge for scanning, connection, and GATT reads.
- `BleSession`: active connection to a device.
- `LogHeader`: minimal metadata for available logs.

## Error taxonomy
- `PermissionDenied`
- `BluetoothOff`
- `DeviceNotFound`
- `ConnectionFailed`
- `GattError`
- `ChecksumMismatch`
- `Timeout`
- `Unknown`

## Adapter interface (conceptual)
- `scan(timeout_ms) -> [DeviceInfo]`
- `connect(device_id) -> Session`
- `disconnect(session)`
- `list_logs(session) -> [LogHeader]`
- `download_log(session, log_id, on_chunk) -> CompletedLog`
- `cancel(session)`

## Session behaviors
- `download_log` supports resume via last offset.
- Chunk callback includes offset, length, and CRC if available.
- Adapter must surface device RSSI and connection state.

## Platform mapping
- Apple: CoreBluetooth
- Android: BLE stack via Kotlin
- Windows: WinRT BLE
- Linux: BlueZ (D‑Bus)

## Logging and diagnostics
- Adapter emits structured events for:
  - Scan start/stop
  - Connect/disconnect
  - Chunk received
  - Retry attempts
  - Error codes
