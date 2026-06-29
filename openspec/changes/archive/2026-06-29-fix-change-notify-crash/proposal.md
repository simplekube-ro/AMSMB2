## Why

The `monitorItem` API (SMB2 Change Notify) crashes with signal 5 (SIGTRAP) or signal 11 (SIGSEGV) when used against a real server. The crash is caused by `async_await` in `Context.swift` using `withUnsafeMutablePointer(to: &cb)` to pass a `CBData` reference through C callback APIs. Per Swift's API contract, the pointer is only valid within the closure, but libsmb2 stores it and invokes the callback later during `wait_for_reply`'s poll loop — at which point the pointer is dangling. Short-lived operations work by luck; Change Notify exposes the undefined behavior because the callback fires after an extended wait.

## What Changes

- **Replace `withUnsafeMutablePointer` with `Unmanaged`**: Use `Unmanaged<CBData>.passUnretained(cb).toOpaque()` to create a stable heap pointer in both `async_await` and `async_await_pdu`. This is the standard Swift pattern for passing object references through C callback APIs.
- **Update `generic_handler`**: Recover the `CBData` reference using `Unmanaged<CBData>.fromOpaque(ptr).takeUnretainedValue()` instead of `bindMemory(to:).pointee`.
- **Enable `testMonitor`**: Remove the `XCTSkipIf` guard and verify the test passes against Docker Samba.

## Capabilities

### New Capabilities
- `safe-callback-pointers`: Replace undefined-behavior pointer passing with `Unmanaged`-based safe pointer management for all async SMB2 operations

### Modified Capabilities

## Impact

- **`AMSMB2/Context.swift`**: Changes to `async_await`, `async_await_pdu`, and `generic_handler` — affects all async SMB2 operations
- **`AMSMB2Tests/SMB2ManagerTests.swift`**: Remove `testMonitor` skip guard
- **Risk**: Since this changes the callback mechanism for ALL operations, all existing tests must pass to verify no regressions
