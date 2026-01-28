# Test Case Templates (Draft)

## BLE Adapter
### Test: Scan returns devices
- **Setup**: Mock adapter with 2 devices
- **Action**: scan(timeout=3000)
- **Assert**: returns 2 devices, RSSI present, no errors

### Test: Connect fails when device missing
- **Setup**: Mock adapter with empty device list
- **Action**: connect("missing")
- **Assert**: error DeviceNotFound

### Test: Download resumes from offset
- **Setup**: Mock adapter returns chunks [0..1024], [1024..2048]
- **Action**: download(resume_offset=1024)
- **Assert**: only chunk 2 returned, CRC verified

### Test: BLE permission denied
- **Setup**: Adapter configured to throw PermissionDenied
- **Action**: scan(timeout=3000)
- **Assert**: error propagated, UI shows guidance

### Test: Mid‑transfer disconnect
- **Setup**: Adapter disconnects after first chunk
- **Action**: download
- **Assert**: ConnectionFailed, resume works on retry

## Formula Engine
### Test: Valid expression parses
- **Input**: `deco_time_min / bottom_time_min`
- **Assert**: AST valid, variables bound

### Test: Invalid syntax
- **Input**: `deco_time_min /`
- **Assert**: validation error with cursor position

### Test: Divide by zero
- **Input**: `otu / bottom_time_min`, bottom_time_min = 0
- **Assert**: result null, warning logged

### Test: Boolean + ternary
- **Input**: `is_ccr and deco_time_min > 0 ? 1 : 0`
- **Assert**: returns 1 for CCR deco dive

### Test: Segment variables
- **Input**: `segment_deco_time_min / segment_time_min`
- **Assert**: resolves segment scope
