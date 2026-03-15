# Disconnect & Timeout Integration Tests

**Date:** 2026-03-15
**File:** `AMSMB2Tests/SMB2DisconnectTimeoutTests.swift`

## Goal

Add integration tests for disconnect behavior and timeout handling — two areas with minimal coverage today (only `testConnectDisconnect` and `testEchoAfterDisconnect` exist).

## Approach

New dedicated test file (Approach B) with the same env-var / `XCTSkipUnless` pattern as existing integration tests. Two MARK sections.

## Test Cases

### MARK: Disconnect Behavior

#### 1. `testGracefulDisconnectWaitsForInFlightOperation`

- Start a 4 MB write in a concurrent `Task`
- Immediately call `disconnectShare(gracefully: true)` from the test body
- After disconnect returns, reconnect and verify the file exists with correct size
- Exercises the `operationLock` / `operationCount` wait loop in `AMSMB2.swift`

#### 2. `testNonGracefulDisconnectFailsInFlightOperation`

- Start a 4 MB write in a concurrent `Task`, capture whether it throws
- Immediately call `disconnectShare(gracefully: false)`
- Verify the write task threw an error (`ENOTCONN` or `ECANCELED`)

#### 3. `testOperationsFailAfterDisconnect`

- Connect, disconnect gracefully
- Try `contents()`, `write()`, `contentsOfDirectory()` — each should throw `POSIXError`
- Verifies the client properly rejects operations on a dead connection

#### 4. `testReconnectAfterDisconnectFullRoundTrip`

- Connect, write a file, disconnect gracefully
- Reconnect, read the file back, verify data matches
- Also verify `echo()` succeeds on the new connection
- Teardown cleans up the test file

### MARK: Timeout Behavior

#### 5. `testShortTimeoutFiresOnLargeWrite`

- Connect with default timeout, then set `smb.timeout = 0.001` (1 ms)
- Attempt a 4 MB write
- Expect `POSIXError(.ETIMEDOUT)`
- Reset timeout in teardown so cleanup can succeed

## Infrastructure

- No Docker/infra changes needed — all tests run against the existing Samba container
- Same `XCTSkipUnless(ProcessInfo.processInfo.environment["SMB_SERVER"] != nil)` guard
- File/directory cleanup via `addTeardownBlock`

## Out of Scope

- Network fault injection (toxiproxy) — saved as a future enhancement
- Connection timeout to unreachable hosts
- Concurrent operations during disconnect
