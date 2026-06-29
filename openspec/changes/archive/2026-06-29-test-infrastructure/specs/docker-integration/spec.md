## ADDED Requirements

### Requirement: Docker Compose configuration for SMB test server

A `test-fixtures/docker-compose.yml` SHALL define a Samba container service using `ghcr.io/simplekube-ro/samba:1.1` that provides a read-write SMB share for integration testing.

#### Scenario: Container starts and serves SMB
- **WHEN** `docker-compose -f test-fixtures/docker-compose.yml up -d` is run
- **THEN** a Samba container SHALL start on port 445 with user `testuser`/`testpass` and a writable share named `testshare`

#### Scenario: Container health check
- **WHEN** the container is running
- **THEN** `smbclient -L localhost -N` SHALL succeed, confirming the SMB service is healthy

### Requirement: Samba configuration for test share

A `test-fixtures/samba/smb.conf` SHALL configure a writable share at `/share` accessible by `testuser`.

#### Scenario: Share is writable
- **WHEN** `testuser` connects to `testshare`
- **THEN** the user SHALL be able to create, read, write, and delete files and directories

### Requirement: Integration test orchestration script

A `scripts/test-integration.sh` SHALL orchestrate the full integration test lifecycle: Docker startup, health check, test execution, and teardown.

#### Scenario: Full integration test run
- **WHEN** `./scripts/test-integration.sh` is run with Docker available
- **THEN** the script SHALL start the Samba container, wait for port 445, run `swift test` with `SMB_SERVER=127.0.0.1 SMB_SHARE=testshare SMB_USER=testuser SMB_PASSWORD=testpass`, stop the container, and exit with the test exit code

#### Scenario: Docker not available
- **WHEN** the script is run without Docker installed or daemon running
- **THEN** the script SHALL exit with a non-zero code and a clear error message

#### Scenario: Container teardown on test failure
- **WHEN** tests fail
- **THEN** the script SHALL still run `docker-compose down` before exiting with the test failure exit code

#### Scenario: Skip Docker flag
- **WHEN** `./scripts/test-integration.sh --skip-docker` is run
- **THEN** the script SHALL skip container start/stop and only run `swift test` with env vars (assumes containers are already running)

### Requirement: Makefile integration

The `Makefile` SHALL include an `integrationtest` target that runs `scripts/test-integration.sh`.

#### Scenario: Make target invocation
- **WHEN** `make integrationtest` is run
- **THEN** the integration test script SHALL execute with default options
