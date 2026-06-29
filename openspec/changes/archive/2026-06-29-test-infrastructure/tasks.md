## 1. Test Isolation

- [x] 1.1 Add `XCTSkipUnless` guard to every server-dependent test method in `SMB2ManagerTests.swift`
- [x] 1.2 Make `server`, `share`, `credential`, `encrypted` lazy vars safe (no force-unwrap)
- [x] 1.3 Verify `swift test` runs cleanly with no env vars (unit tests pass, integration tests skip)

## 2. Test Utilities Extraction

- [x] 2.1 Create `AMSMB2Tests/TestUtilities.swift` with shared `randomData(size:)` function
- [x] 2.2 Create `SMBIntegrationTestCase` base class with shared setup: `server`, `share`, `credential`, `encrypted` properties, `setUpWithError()` with `XCTSkipUnless`, `connect()`/`disconnect()` helpers
- [x] 2.3 Remove `randomData(size:)` from `SMB2ManagerTests.swift`, `SMB2DisconnectTimeoutTests.swift`, and `SMB2IntegrationTests.swift` — use shared version
- [x] 2.4 Migrate `SMB2IntegrationTests` and `SMB2ManagerTests` (integration tests only) to inherit from `SMBIntegrationTestCase`
- [x] 2.5 Verify all tests still pass after extraction

## 3. Unit Test Extraction and Expansion

- [x] 3.1 Create `AMSMB2Tests/SMB2ManagerUnitTests.swift` with extracted unit tests (`testNSCodable`, `testCoding`, `testNSCopy`)
- [x] 3.2 Add unit test for `SMB2Manager.init` with invalid (non-smb) URL returning nil
- [x] 3.3 Remove the 3 unit tests from `SMB2ManagerTests.swift` (now in `SMB2ManagerUnitTests`)

## 4. Public Type Unit Tests

- [x] 4.1 Create `AMSMB2Tests/SMB2TypeTests.swift`
- [x] 4.2 Add SMB2Client tests: `debugDescription`, `customMirror`
- [x] 4.3 Add SMB2FileChangeType tests: OptionSet operations, `description`
- [x] 4.4 Add SMB2FileChangeAction tests: equality, hashing, `description`
- [x] 4.5 Add SMB2FileChangeInfo tests: equality

## 5. Docker Integration Infrastructure

- [x] 5.1 Create `test-fixtures/samba/smb.conf` with writable `testshare`
- [x] 5.2 Create `test-fixtures/docker-compose.yml` with `ghcr.io/simplekube-ro/samba:1.1`
- [x] 5.3 Create `scripts/test-integration.sh` with Docker lifecycle orchestration
- [x] 5.4 Make `scripts/test-integration.sh` executable
- [x] 5.5 Add `integrationtest` target to `Makefile`
- [x] 5.6 Verify `make integrationtest` runs end-to-end with Docker

## 6. Integration Test Coverage

- [x] 6.1 Create `AMSMB2Tests/SMB2IntegrationTests.swift` with base class setup (connect/skip pattern)
- [x] 6.2 Add `testAppend` — write then append, verify combined contents
- [x] 6.3 Add `testRemoveItem` — verify generic remove for both file and directory
- [x] 6.4 Add `testCopyContentsOfItem` — server-side copy, verify destination data
- [x] 6.5 Add `testEcho` — standalone echo on active connection
- [x] 6.6 Add `testEchoAfterDisconnect` — echo after disconnect throws
- [x] 6.7 Add `testProgressCancellation` — return false from write progress handler, verify cancellation
- [x] 6.8 Add `testReadProgressCancellation` — return false from read progress handler
- [x] 6.9 Add `testReadNonExistentPath` — verify POSIXError on missing path
- [x] 6.10 Add `testConnectInvalidCredentials` — verify auth failure error
- [x] 6.11 Add `testConnectNonExistentShare` — verify error on bad share name
- [x] 6.12 Add `testSmbClientAccessor` — verify smbClient returns valid client after connect

## 7. Documentation

- [x] 7.1 Add `git submodule update --init` to CLAUDE.md build instructions
