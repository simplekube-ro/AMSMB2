# credential-redaction Specification

## Purpose
Ensure that user credentials managed by `SMB2Manager` are never leaked through serialization or debug output. Passwords MUST be excluded from every persistence path (Codable and NSSecureCoding) and the username MUST be redacted in debug representations, while in-memory copying continues to preserve the password so the manager remains functional.

## Requirements

### Requirement: Password excluded from Codable encoding
The `Codable` encoding of `SMB2Manager` SHALL NOT include the `_password` value. Decoding SHALL remain backward compatible by still reading `_password` when present, but SHALL default to an empty string when it is absent.

#### Scenario: Password absent from Codable output
- **WHEN** an `SMB2Manager` with a non-empty password is encoded via `JSONEncoder`
- **THEN** `encode(to:)` SHALL NOT write `_password`, and the resulting JSON SHALL contain no password field

#### Scenario: Decoding tolerates missing password
- **WHEN** an `SMB2Manager` is decoded from JSON that omits `_password`
- **THEN** `init(from:)` SHALL succeed and the decoded object's password SHALL be an empty string

#### Scenario: Decoding remains backward compatible
- **WHEN** an `SMB2Manager` is decoded from older JSON that still contains `_password`
- **THEN** `init(from:)` SHALL decode that value rather than failing

### Requirement: Password excluded from NSSecureCoding encoding
The `NSSecureCoding` encoding of `SMB2Manager` SHALL NOT include the `_password` value. Decoding SHALL remain backward compatible by still reading `_password` when present, but SHALL default to an empty string when it is absent.

#### Scenario: Password absent from archive
- **WHEN** an `SMB2Manager` with a non-empty password is archived via `NSKeyedArchiver`
- **THEN** `encode(with:)` SHALL NOT write `_password`, and unarchiving SHALL yield an object whose password is an empty string

#### Scenario: Unarchiving remains backward compatible
- **WHEN** an `SMB2Manager` is unarchived from an archive that still contains `_password`
- **THEN** `init?(coder:)` SHALL decode that value rather than discarding it

### Requirement: Credentials excluded from debug output
The debug representation of `SMB2Manager` SHALL NOT expose credentials. `customMirror` SHALL display `"<redacted>"` for the user label and SHALL NOT include any password entry. Because `debugDescription` iterates `customMirror.children`, it SHALL therefore be free of credentials.

#### Scenario: User label is redacted in mirror
- **WHEN** the `customMirror` of an `SMB2Manager` is inspected
- **THEN** the user label SHALL be `"<redacted>"` and there SHALL be no password child

#### Scenario: Debug description hides the username
- **WHEN** `debugDescription` is produced for an `SMB2Manager` with a known username
- **THEN** the output SHALL NOT contain the username string and SHALL contain `"<redacted>"`

### Requirement: customMirror conditional fields are correct
The `customMirror` of `SMB2Manager` SHALL append the domain child only when `_domain` is non-empty, SHALL append the workstation child only when `_workstation` is non-empty, and SHALL append the workstation child exactly once.

#### Scenario: Domain shown only when present
- **WHEN** `customMirror` is built for an `SMB2Manager` whose `_domain` is empty
- **THEN** no domain child SHALL be appended; **WHEN** `_domain` is non-empty, exactly one domain child SHALL be appended

#### Scenario: Workstation shown only when present and exactly once
- **WHEN** `customMirror` is built for an `SMB2Manager` whose `_workstation` is empty
- **THEN** no workstation child SHALL be appended; **WHEN** `_workstation` is non-empty, exactly one workstation child SHALL be appended (no duplicate)

### Requirement: NSCopying preserves the in-memory password
`copy(with:)` SHALL pass `_password` to the new instance so that a copied `SMB2Manager` remains functional. This is an in-memory operation and is distinct from the persistence paths that redact the password.

#### Scenario: Copy retains password
- **WHEN** an `SMB2Manager` with a non-empty password is copied via `copy(with:)`
- **THEN** the copied instance SHALL retain the same password
