## Why

Running `swift test` crashes because server-dependent integration tests force-unwrap environment variables via lazy vars, killing the entire test process — including the 3 pure unit tests that need no server. The build itself fails for new clones because the `Dependencies/libsmb2` git submodule isn't documented as a prerequisite. There is no local integration test infrastructure (Docker-based SMB server), and several public API surfaces — especially the recently exposed `SMB2Client`, `SMB2FileHandle`, and file monitoring types — have zero test coverage.

## What Changes

- **Fix test isolation**: Guard all server-dependent tests with `XCTSkipUnless` so `swift test` runs cleanly without a server, executing unit tests and skipping integration tests.
- **Add Docker-based integration testing**: Create a `docker-compose.yml` with a Samba container, a `test-integration.sh` script to orchestrate Docker lifecycle + `swift test`, and a Makefile target.
- **Expand unit test coverage**: Add tests for public types that currently have no coverage — `SMB2Client`, `SMB2FileHandle`, `AsyncInputStream`, `SMB2FileChangeType`/`Action`/`Info`.
- **Expand integration test coverage**: Add tests for untested API operations — `append()`, `removeItem()`, `copyContentsOfItem()`, `echo()`, progress cancellation, error handling paths, and the `smbClient` public accessor.
- **Deduplicate test helpers**: Extract `randomData(size:)` (duplicated in 3 test files) and shared setup boilerplate (server/share/credential/encrypted vars, `setUpWithError()`) into a shared test utilities file or base `XCTestCase` subclass.
- **Document build prerequisites**: Add `git submodule update --init` to CLAUDE.md.

## Capabilities

### New Capabilities
- `test-isolation`: Guard server-dependent tests so `swift test` works without a server, separating unit from integration tests
- `docker-integration`: Docker-based SMB test server with orchestration script and Makefile integration
- `unit-test-coverage`: Unit tests for public types that need no server (SMB2Client, SMB2FileHandle, AsyncInputStream, file monitoring types)
- `integration-test-coverage`: Integration tests for untested API operations requiring a live SMB server
- `test-utilities`: Shared test helpers (`randomData`, server config base class) extracted from duplicated code across test files

### Modified Capabilities

## Impact

- **Test files**: `AMSMB2Tests/SMB2ManagerTests.swift` modified; 4-5 new test files created in `AMSMB2Tests/`
- **Test utilities**: New `AMSMB2Tests/TestUtilities.swift` (or similar) with shared `randomData(size:)` and `SMBTestCase` base class
- **Build infrastructure**: New `test-fixtures/` directory, `scripts/test-integration.sh`, Makefile updates
- **Documentation**: CLAUDE.md updated with submodule init instructions
- **No production code changes**: All changes are test infrastructure and documentation only
