## 1. Fix Callback Pointer Management

- [x] 1.1 Update `generic_handler` in `Context.swift` to recover `CBData` via `Unmanaged<CBData>.fromOpaque(_:).takeUnretainedValue()`
- [x] 1.2 Update `async_await` to pass `CBData` pointer via `Unmanaged.passUnretained(cb).toOpaque()` instead of `withUnsafeMutablePointer`
- [x] 1.3 Update `async_await_pdu` to pass `CBData` pointer via `Unmanaged.passUnretained(cb).toOpaque()` instead of `withUnsafeMutablePointer`

## 2. Enable testMonitor

- [x] 2.1 Remove `XCTSkipIf` guard from `testMonitor` in `SMB2ManagerTests.swift`
- [x] 2.2 Verify `testMonitor` passes against Docker Samba

## 3. Regression Testing

- [x] 3.1 Run full test suite (`make integrationtest`) and verify 0 failures
