## 1. File Setup

- [x] 1.1 Create `AMSMB2Tests/SMB2DisconnectTimeoutTests.swift` with class boilerplate (imports, env-var lazy properties, `XCTSkipUnless` guard, `randomData` helper)

## 2. Disconnect Behavior Tests

- [x] 2.1 Implement `testGracefulDisconnectWaitsForInFlightOperation` — concurrent 4 MB write + graceful disconnect, verify file exists after reconnect
- [x] 2.2 Implement `testNonGracefulDisconnectFailsInFlightOperation` — concurrent 4 MB write + non-graceful disconnect, verify write throws
- [x] 2.3 Implement `testOperationsFailAfterDisconnect` — verify `contents()`, `write()`, `contentsOfDirectory()` all throw `POSIXError` after disconnect
- [x] 2.4 Implement `testReconnectAfterDisconnectFullRoundTrip` — write, disconnect, reconnect, read back, verify data + echo

## 3. Timeout Behavior Tests

- [x] 3.1 Implement `testShortTimeoutFiresOnLargeWrite` — set timeout to 0.001s, attempt 4 MB write, expect `ETIMEDOUT`

## 4. Verification

- [x] 4.1 Run `swift build` to verify compilation
- [x] 4.2 Run `swift test` to verify non-integration tests still pass (integration tests will skip without Docker)
