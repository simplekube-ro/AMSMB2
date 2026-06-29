## 1. Test (Red)

- [x] 1.1 Write `testDisconnectCompletesPromptly` in `SMB2DisconnectTimeoutTests.swift` — connect, measure time around `disconnectShare()`, assert it completes within 2 seconds (fails against current 60s timeout bug)

## 2. Fix (Green)

- [x] 2.1 Rewrite `SMB2Client.disconnect()` in `Context.swift` — replace `async_await` with fire-and-forget pattern: queue disconnect PDU, flush with `smb2_service(POLLOUT)`, then stop socket monitoring and fail pending operations, all in one `eventLoopQueue.sync` block

## 3. Verify

- [x] 3.1 Run `swift build` to verify compilation
- [x] 3.2 Run `swift test` to verify all tests pass
