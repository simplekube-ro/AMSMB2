## ADDED Requirements

### Requirement: Server-dependent tests skip gracefully without a server

All test methods that require a live SMB server SHALL be guarded with `try XCTSkipUnless(ProcessInfo.processInfo.environment["SMB_SERVER"] != nil, "SMB server not configured")` as the first statement. The guard SHALL prevent force-unwrap crashes when environment variables are not set.

#### Scenario: Running swift test without server environment variables
- **WHEN** `swift test` is run without `SMB_SERVER`, `SMB_SHARE`, `SMB_USER`, or `SMB_PASSWORD` environment variables set
- **THEN** all server-dependent tests SHALL be skipped with the message "SMB server not configured" and the test process SHALL exit cleanly (no crashes)

#### Scenario: Running swift test with server environment variables
- **WHEN** `swift test` is run with all required SMB environment variables set
- **THEN** all server-dependent tests SHALL execute normally against the configured server

### Requirement: Unit tests always execute

The pure unit tests (`testNSCodable`, `testCoding`, `testNSCopy`) SHALL always execute regardless of whether SMB environment variables are set. These tests SHALL be in a separate test class from server-dependent tests.

#### Scenario: Unit tests pass without any environment configuration
- **WHEN** `swift test` is run in a clean environment with no SMB environment variables
- **THEN** unit tests SHALL execute and pass, and `swift test` SHALL report at least 3 passing tests

### Requirement: Lazy var force-unwrap elimination

The `server`, `share`, `credential`, and `encrypted` lazy vars in `SMB2ManagerTests` SHALL NOT force-unwrap environment variables. They SHALL use safe unwrapping that does not crash the test process.

#### Scenario: Lazy var access without environment variables
- **WHEN** a test method accesses the `server` lazy var without `SMB_SERVER` set
- **THEN** the test SHALL skip (via the XCTSkipUnless guard) before the lazy var is evaluated, preventing any crash
