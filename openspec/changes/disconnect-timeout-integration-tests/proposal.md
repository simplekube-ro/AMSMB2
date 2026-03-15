## Why

The AMSMB2 library has minimal integration test coverage for disconnect behavior and timeout handling. Only two superficial tests exist (`testConnectDisconnect` and `testEchoAfterDisconnect`), leaving the graceful disconnect drain mechanism, non-graceful teardown of in-flight operations, post-disconnect error reporting, and the per-operation timeout path completely untested. These are critical resilience paths that affect production reliability.

## What Changes

- Add a new `SMB2DisconnectTimeoutTests.swift` integration test file with 5 focused tests
- Cover graceful disconnect waiting for in-flight operations to complete
- Cover non-graceful disconnect failing in-flight operations
- Verify multiple operation types fail with correct errors after disconnect
- Verify full reconnect-after-disconnect round-trip (write, disconnect, reconnect, read back)
- Verify the per-operation timeout mechanism fires correctly

## Capabilities

### New Capabilities

- `disconnect-timeout-tests`: Integration tests covering disconnect behavior (graceful/non-graceful) and operation timeout handling against a live SMB server

### Modified Capabilities

_None — this change adds test coverage only, no behavioral changes._

## Impact

- **Code:** New file `AMSMB2Tests/SMB2DisconnectTimeoutTests.swift`
- **Infrastructure:** No changes — tests run against the existing Docker Samba container
- **APIs:** No changes — tests exercise the existing public API (`disconnectShare`, `timeout`, `contents`, `write`, `echo`)
- **Dependencies:** No new dependencies
