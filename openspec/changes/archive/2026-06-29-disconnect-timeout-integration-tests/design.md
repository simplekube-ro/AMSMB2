## Context

AMSMB2 has a mature integration test suite (~53 tests) running against a Dockerized Samba server. However, disconnect and timeout paths have only 2 superficial tests. The library's event-loop architecture (`Context.swift`) has a per-operation semaphore/timeout mechanism and a graceful-disconnect drain loop (`AMSMB2.swift`) that are both untested.

Existing integration test files follow a consistent pattern: `XCTestCase` subclass with `@unchecked Sendable`, env-var lazy properties, `XCTSkipUnless` guard, `addTeardownBlock` cleanup, and `async` test methods.

## Goals / Non-Goals

**Goals:**
- Test graceful disconnect draining in-flight operations
- Test non-graceful disconnect failing in-flight operations
- Test that operations produce correct errors after disconnect
- Test reconnect-after-disconnect with full data round-trip
- Test that the per-operation timeout mechanism fires

**Non-Goals:**
- Network fault injection (future toxiproxy work)
- Connection timeout to unreachable hosts
- Concurrent multi-operation disconnect races
- Changes to library behavior — tests only

## Decisions

### 1. Dedicated test file vs. extending existing files

**Choice:** New `SMB2DisconnectTimeoutTests.swift`

**Rationale:** Connection lifecycle/resilience tests are a distinct concern from file operation tests. A dedicated file allows `--filter SMB2DisconnectTimeoutTests` for targeted runs. The ~15 lines of boilerplate duplication is a worthwhile trade-off for clarity.

**Alternatives:** Extending `SMB2IntegrationTests.swift` (rejected — already covers diverse topics) or `SMB2ManagerTests.swift` (rejected — 644 lines, disconnect tests would be lost).

### 2. Testing graceful disconnect with concurrent Task

**Choice:** Launch a 4 MB write in a Swift `Task`, then call `disconnectShare(gracefully: true)` from the test body. After disconnect returns, reconnect and verify the file exists with correct size.

**Rationale:** The `operationCount`/`operationLock` mechanism in `AMSMB2.swift` is what makes graceful disconnect wait. A large write ensures the operation is still in-flight when disconnect is called. Verifying the file on disk after reconnect proves the write completed.

### 3. Testing timeout with very short timeout value

**Choice:** Set `smb.timeout = 0.001` (1 ms) after connecting, then attempt a 4 MB write.

**Rationale:** This exercises the `semaphore.wait(timeout:)` → `isAbandoned` path in `Context.swift:736-743` without needing a slow/stalled server. The 1 ms timeout is short enough that any real I/O will exceed it. The timeout is reset in teardown so cleanup succeeds.

**Alternative:** A stalled server via toxiproxy (deferred to future work).

## Risks / Trade-offs

- **[Timing sensitivity in graceful disconnect test]** → The write must still be in-flight when `disconnectShare` is called. Using 4 MB data makes this very likely against a local Docker container. If the test becomes flaky on fast machines, increase the data size.
- **[Timeout test may not trigger ETIMEDOUT if write completes instantly]** → 4 MB against a local container with 1 ms timeout should always trigger timeout. If not, reduce timeout further or increase data size.
- **[Non-graceful disconnect error type uncertainty]** → The write may fail with `ENOTCONN`, `ECANCELED`, or another error depending on timing. The test should accept any error rather than asserting a specific code.
