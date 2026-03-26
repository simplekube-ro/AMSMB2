## 1. Test Isolation

- [ ] 1.1 Add `XCTSkipUnless` guard to every server-dependent test method in `SMB2ManagerTests.swift`
- [ ] 1.2 Make `server`, `share`, `credential`, `encrypted` lazy vars safe (no force-unwrap)
- [ ] 1.3 Verify `swift test` runs cleanly with no env vars (unit tests pass, integration tests skip)

## 2. Test Utilities Extraction

- [ ] 2.1 Create `AMSMB2Tests/TestUtilities.swift` with shared `randomData(size:)` function
- [ ] 2.2 Create `SMBIntegrationTestCase` base class with shared setup: `server`, `share`, `credential`, `encrypted` properties, `setUpWithError()` with `XCTSkipUnless`, `connect()`/`disconnect()` helpers
- [ ] 2.3 Remove `randomData(size:)` from `SMB2ManagerTests.swift`, `SMB2DisconnectTimeoutTests.swift`, and `SMB2IntegrationTests.swift` — use shared version
- [ ] 2.4 Migrate `SMB2IntegrationTests` and `SMB2ManagerTests` (integration tests only) to inherit from `SMBIntegrationTestCase`
- [ ] 2.5 Verify all tests still pass after extraction

## 3. Unit Test Extraction and Expansion

- [ ] 3.1 Create `AMSMB2Tests/SMB2ManagerUnitTests.swift` with extracted unit tests (`testNSCodable`, `testCoding`, `testNSCopy`)
- [ ] 3.2 Add unit test for `SMB2Manager.init` with invalid (non-smb) URL returning nil
- [ ] 3.3 Remove the 3 unit tests from `SMB2ManagerTests.swift` (now in `SMB2ManagerUnitTests`)

## 4. Public Type Unit Tests

- [ ] 4.1 Create `AMSMB2Tests/SMB2TypeTests.swift`
- [ ] 4.2 Add SMB2Client tests: `debugDescription`, `customMirror`
- [ ] 4.3 Add SMB2FileChangeType tests: OptionSet operations, `description`
- [ ] 4.4 Add SMB2FileChangeAction tests: equality, hashing, `description`
- [ ] 4.5 Add SMB2FileChangeInfo tests: equality

## 5. Docker Integration Infrastructure

- [ ] 5.1 Create `test-fixtures/samba/smb.conf` with writable `testshare`
- [ ] 5.2 Create `test-fixtures/docker-compose.yml` with `ghcr.io/simplekube-ro/samba:1.1`
- [ ] 5.3 Create `scripts/test-integration.sh` with Docker lifecycle orchestration
- [ ] 5.4 Make `scripts/test-integration.sh` executable
- [ ] 5.5 Add `integrationtest` target to `Makefile`
- [ ] 5.6 Verify `make integrationtest` runs end-to-end with Docker

## 6. Integration Test Coverage

- [ ] 6.1 Create `AMSMB2Tests/SMB2IntegrationTests.swift` with base class setup (connect/skip pattern)
- [ ] 6.2 Add `testAppend` — write then append, verify combined contents
- [ ] 6.3 Add `testRemoveItem` — verify generic remove for both file and directory
- [ ] 6.4 Add `testCopyContentsOfItem` — server-side copy, verify destination data
- [ ] 6.5 Add `testEcho` — standalone echo on active connection
- [ ] 6.6 Add `testEchoAfterDisconnect` — echo after disconnect throws
- [ ] 6.7 Add `testProgressCancellation` — return false from write progress handler, verify cancellation
- [ ] 6.8 Add `testReadProgressCancellation` — return false from read progress handler
- [ ] 6.9 Add `testReadNonExistentPath` — verify POSIXError on missing path
- [ ] 6.10 Add `testConnectInvalidCredentials` — verify auth failure error
- [ ] 6.11 Add `testConnectNonExistentShare` — verify error on bad share name
- [ ] 6.12 Add `testSmbClientAccessor` — verify smbClient returns valid client after connect

## 7. Documentation

- [ ] 7.1 Add `git submodule update --init` to CLAUDE.md build instructions
