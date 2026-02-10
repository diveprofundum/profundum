# Test Case Templates

## BLE / Dive Computer Import
### Test: MockBLETransport read/write
- **Setup**: MockBLETransport with canned response data
- **Action**: write characteristic, read response
- **Assert**: data round-trips correctly, writeWithoutResponse used

### Test: Import with missing fingerprint
- **Setup**: In-memory DB, dive data with no prior fingerprint
- **Action**: import via DiveComputerImportService
- **Assert**: dive created, fingerprint stored in dive_source_fingerprints

### Test: Import with duplicate fingerprint
- **Setup**: In-memory DB with existing fingerprint
- **Action**: reimport same dive data
- **Assert**: dive skipped, no duplicate created

### Test: Multi-computer merge
- **Setup**: Two dives from different serials within 120s window
- **Action**: import both
- **Assert**: single dive with groupId, two fingerprint records

### Test: BLE disconnect mid-transfer
- **Setup**: MockBLETransport configured to error after N bytes
- **Action**: download
- **Assert**: DiveComputerError.connectionFailed, partial data not persisted

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
