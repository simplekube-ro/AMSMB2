## Capability: test-utilities

Shared test helpers and base class extracted from duplicated code across test files.

## Requirements

### R1: Shared `randomData(size:)` function
- Single implementation in `TestUtilities.swift`
- Removed from `SMB2ManagerTests.swift`, `SMB2DisconnectTimeoutTests.swift`, `SMB2IntegrationTests.swift`
- All call sites updated to use the shared version

### R2: Shared integration test base class
- `SMBIntegrationTestCase` (or similar) subclass of `XCTestCase`
- Provides `server`, `share`, `credential`, `encrypted` properties from environment variables
- Provides `setUpWithError()` with `XCTSkipUnless` guard for server availability
- Provides `connect()` / `disconnect()` helpers

### R3: No test behavior changes
- All existing tests produce identical results
- Integration tests still skip when server unavailable
- Unit tests still run without server

## Verification

- `swift test` passes with no environment variables (unit tests run, integration tests skip)
- `make integrationtest` passes with Docker (all tests run)
- No duplicate `randomData` definitions in the test target (grep confirms single definition)
