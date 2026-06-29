## Context

AMSMB2 is a Swift SMB2/3 client library wrapping libsmb2. It has a single test file (`AMSMB2Tests/SMB2ManagerTests.swift`) containing both pure unit tests and server-dependent integration tests in one class. The integration tests force-unwrap environment variables at lazy-var evaluation time, crashing the entire test process when no server is configured.

The project depends on a git submodule (`Dependencies/libsmb2`) that must be initialized before building. This prerequisite is not documented.

The RandomPlayer project (a consumer of this library) has a working Docker-based integration test pattern using `ghcr.io/simplekube-ro/samba:1.1` and a shell script orchestrator. We can reuse the same Samba image and adopt a similar pattern adapted for library-level `swift test` rather than XCUITests.

Several public types (`SMB2Client`, `SMB2FileHandle`, `AsyncInputStream`, file monitoring types) and API operations (`append`, `removeItem`, `copyContentsOfItem`, `echo`, error paths, progress cancellation) have no test coverage.

## Goals / Non-Goals

**Goals:**
- `swift test` runs cleanly without a server, executing unit tests and skipping integration tests
- Docker-based integration testing via a single `make integrationtest` command
- Test coverage for all public types and all public API methods on `SMB2Manager`
- Documented build prerequisites in CLAUDE.md

**Non-Goals:**
- Separate SwiftPM test targets (keeping single `AMSMB2Tests` target to avoid Package.swift complexity)
- CI/CD pipeline configuration (infrastructure only, CI integration is a future change)
- Performance benchmarks or stress testing
- ObjC compatibility layer testing (the `__` prefixed methods are thin wrappers; testing them adds cost with minimal value)
- Testing private/internal APIs beyond what `@testable import` already provides in existing tests

## Decisions

### 1. XCTSkipUnless over separate test targets

Guard server-dependent tests with `try XCTSkipUnless(ProcessInfo.processInfo.environment["SMB_SERVER"] != nil, "SMB server not configured")` at the start of each test method.

**Rationale**: Avoids Package.swift changes and test target proliferation. The skip message clearly explains why tests were skipped. This is the idiomatic XCTest pattern for conditional tests.

**Alternative considered**: Separate `AMSMB2UnitTests` and `AMSMB2IntegrationTests` targets in Package.swift. Rejected because it adds build complexity and the library only has one module to test.

### 2. Reuse existing test class, add new test files

Keep `SMB2ManagerTests` as the integration test class (add skip guards). Create new test files for:
- `SMB2ManagerUnitTests.swift` — extracted unit tests plus new ones for serialization edge cases
- `SMB2TypeTests.swift` — public type tests (SMB2Client, SMB2FileHandle, AsyncInputStream, file monitoring types)
- `SMB2IntegrationTests.swift` — new integration tests for untested API operations

**Rationale**: Keeps existing test structure recognizable while organizing new tests logically. One file per concern.

### 3. Docker Samba container matching RandomPlayer pattern

Use `ghcr.io/simplekube-ro/samba:1.1` with a read-write share (unlike RandomPlayer's read-only shares, since AMSMB2 tests write/delete files).

Docker compose config:
- Single `smb-test` service on port 445
- Volume mount from `test-fixtures/data/` (empty dir, tests create their own files)
- User: `testuser` / `testpass`
- Share name: `testshare` with read-write access

**Rationale**: The existing tests already expect `SMB_SERVER`, `SMB_SHARE`, `SMB_USER`, `SMB_PASSWORD` environment variables. The script sets these to match the Docker container.

### 4. Shell script orchestrator

`scripts/test-integration.sh` follows the RandomPlayer pattern:
1. Verify Docker is running
2. `docker-compose up -d`
3. Wait for port 445 (health check loop)
4. Run `swift test` with env vars
5. `docker-compose down` (always, even on failure)
6. Report pass/fail count

**Rationale**: Consistent with existing project patterns. Shell script is portable and requires no additional dependencies.

### 5. Test file organization

```
AMSMB2Tests/
├── SMB2ManagerTests.swift         # existing, add XCTSkipUnless guards
├── SMB2ManagerUnitTests.swift     # pure unit tests (no server)
├── SMB2TypeTests.swift            # public type unit tests (no server)
└── SMB2IntegrationTests.swift     # new integration tests (needs server)
```

## Risks / Trade-offs

**[Risk] Docker not available in all dev environments** → The `test-integration.sh` script checks for Docker upfront and fails with a clear message. Unit tests always work via plain `swift test`.

**[Risk] Port 445 conflict with local SMB services** → macOS does not run SMB on 445 by default. If conflict occurs, the health check will fail with a clear timeout message. A future enhancement could make the port configurable.

**[Risk] Samba container image availability** → Using an existing image from `ghcr.io/simplekube-ro/` that's already used in RandomPlayer. If registry is unavailable, Docker will fail with a clear pull error.

**[Trade-off] Single test target vs. multiple** → Simpler Package.swift but requires `XCTSkipUnless` discipline in every integration test method. Accepted because it's the standard XCTest pattern.
