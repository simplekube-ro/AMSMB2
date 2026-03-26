## 1. Tests First (TDD Red Phase)

- [ ] 1.1 Add test `testCodableOmitsPassword`: create SMB2Manager with known password, encode to JSON via JSONEncoder, decode JSON to dictionary, assert "password" key is absent
- [ ] 1.2 Add test `testCodableDecodesLegacyArchive`: create JSON string with password field present, decode via JSONDecoder, assert object is valid and password field is empty string
- [ ] 1.3 Add test `testNSCodingOmitsPassword`: create SMB2Manager, archive via NSKeyedArchiver, unarchive, assert password is empty (verify via re-encoding to JSON and checking absence)
- [ ] 1.4 Add test `testDebugDescriptionRedactsCredentials`: create SMB2Manager with known user, assert debugDescription does NOT contain the username, assert it contains "<redacted>"
- [ ] 1.5 Add test `testCustomMirrorDomainWorkstation`: create SMB2Manager with domain="CORP" and workstation="WS1", verify mirror contains both; create another with empty domain/workstation, verify mirror does NOT contain domain or workstation labels
- [ ] 1.6 Add test `testCopyPreservesPassword`: create SMB2Manager, copy, verify copy can connect with same credentials (or verify via encoding the copy — password should still be empty in encoding but the in-memory object should work)

## 2. Implementation (TDD Green Phase)

- [ ] 2.1 In `encode(to:)`: remove `try container.encode(_password, forKey: .password)`
- [ ] 2.2 In `encode(with:)`: remove `aCoder.encode(_password, forKey: CodingKeys.password.stringValue)`
- [ ] 2.3 In `customMirror`: change `c.append((label: "user", value: _user))` to `c.append((label: "user", value: "<redacted>"))`
- [ ] 2.4 In `customMirror`: fix `if _domain.isEmpty` → `if !_domain.isEmpty`
- [ ] 2.5 In `customMirror`: fix `if _workstation.isEmpty` → `if !_workstation.isEmpty`, remove duplicate line
- [ ] 2.6 Run tests — all new tests should pass green

## 3. Verification

- [ ] 3.1 Run full test suite (`swift test`) — all tests pass
- [ ] 3.2 Verify existing `testNSCodable` and `testCoding` tests still pass (they may need updating if they assert password round-trips)
