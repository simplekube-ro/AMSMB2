# test-utilities Specification

## Purpose
Shared test helpers and base class extracted from duplicated code across test files. This capability provides a single shared `randomData(size:)` function, a reusable integration-test base class, and guarantees that consolidating these helpers introduces no change in test behavior.

## Requirements

### Requirement: Shared `randomData(size:)` function

A single shared `randomData(size:)` function SHALL exist in `TestUtilities.swift`, with the duplicate implementations removed from the other test files and all call sites updated to use the shared version.

#### Scenario: Single implementation in TestUtilities.swift
- **WHEN** the test target is built
- **THEN** `randomData(size:)` SHALL have a single implementation in `TestUtilities.swift`
- **AND** it SHALL be removed from `SMB2ManagerTests.swift`, `SMB2DisconnectTimeoutTests.swift`, and `SMB2IntegrationTests.swift`
- **AND** all call sites SHALL use the shared version

#### Scenario: No duplicate definitions remain
- **WHEN** the test target is searched for `randomData` definitions
- **THEN** exactly one definition SHALL be found (grep confirms a single definition)

### Requirement: Shared integration test base class

A shared `SMBIntegrationTestCase` (or similar) base class SHALL provide environment-derived connection properties, a server-availability skip guard, and connection helpers for integration tests.

#### Scenario: Base class provides environment-derived properties
- **WHEN** a test subclasses `SMBIntegrationTestCase`
- **THEN** the base class SHALL be a subclass of `XCTestCase`
- **AND** it SHALL provide `server`, `share`, `credential`, and `encrypted` properties derived from environment variables

#### Scenario: Base class skips when server unavailable
- **WHEN** `setUpWithError()` runs
- **THEN** it SHALL apply an `XCTSkipUnless` guard for server availability

#### Scenario: Base class provides connection helpers
- **WHEN** a subclass test needs to establish or tear down a connection
- **THEN** the base class SHALL provide `connect()` and `disconnect()` helpers

### Requirement: No test behavior changes

Consolidating the shared helpers and base class SHALL NOT change test behavior; all existing tests SHALL produce identical results.

#### Scenario: Existing tests produce identical results
- **WHEN** the refactored test suite is run
- **THEN** all existing tests SHALL produce identical results

#### Scenario: Tests skip and run correctly without a server
- **WHEN** `swift test` is run with no SMB environment variables
- **THEN** integration tests SHALL still skip
- **AND** unit tests SHALL still run

#### Scenario: All tests run with Docker
- **WHEN** `make integrationtest` is run with Docker available
- **THEN** all tests SHALL run and pass
