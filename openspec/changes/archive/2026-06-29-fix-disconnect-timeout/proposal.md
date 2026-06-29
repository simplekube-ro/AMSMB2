## Why

`SMB2Client.disconnect()` always blocks for the full timeout duration (default 60s) because socket monitoring is stopped before the disconnect PDU is sent. The `DispatchSource` that would flush the PDU and receive the server's response is already nil by the time `async_await` runs, so the semaphore waits until `ETIMEDOUT` — which `try?` silently swallows. Every call to `disconnectShare()` wastes 60 seconds.

## What Changes

- Rewrite `SMB2Client.disconnect()` to use the same fire-and-forget pattern that `shutdown()` already uses: queue the disconnect PDU, flush it synchronously with `smb2_service(POLLOUT)`, then tear down socket monitoring and fail pending operations
- Remove the `async_await` round-trip from `disconnect()` since no caller inspects the disconnect result
- Add a TDD test that verifies `disconnect()` completes promptly (not blocked by timeout)

## Capabilities

### New Capabilities

- `disconnect-fix`: Fix the disconnect sequencing bug and add test coverage for prompt disconnect behavior

### Modified Capabilities

_None — the public API (`disconnectShare`) is unchanged. This fixes an internal implementation bug._

## Impact

- **Code:** `AMSMB2/Context.swift` — `disconnect()` method (~4 lines changed)
- **Tests:** New test verifying disconnect completes without timeout delay
- **APIs:** No public API changes
- **Dependencies:** None
