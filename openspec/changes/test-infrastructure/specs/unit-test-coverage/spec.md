## ADDED Requirements

### Requirement: SMB2Manager serialization unit tests

A `SMB2ManagerUnitTests` class SHALL contain the existing unit tests (`testNSCodable`, `testCoding`, `testNSCopy`) extracted from `SMB2ManagerTests`, plus additional serialization edge case tests.

#### Scenario: NSCoding roundtrip preserves properties
- **WHEN** an SMB2Manager is archived and unarchived via NSKeyedArchiver/NSKeyedUnarchiver
- **THEN** the `url` and `timeout` properties SHALL be equal to the original

#### Scenario: Codable roundtrip preserves properties
- **WHEN** an SMB2Manager is encoded to JSON and decoded back
- **THEN** the `url` and `timeout` properties SHALL be equal to the original

#### Scenario: Codable rejects invalid URL schemes
- **WHEN** JSON with a non-smb URL scheme is decoded
- **THEN** decoding SHALL throw an error

#### Scenario: NSCopy creates independent copy
- **WHEN** an SMB2Manager is copied via NSCopying
- **THEN** the copy SHALL have equal `url` property to the original

#### Scenario: Init with invalid URL returns nil
- **WHEN** `SMB2Manager(url:credential:)` is called with a non-smb URL
- **THEN** the initializer SHALL return nil

### Requirement: SMB2Client public interface unit tests

A `SMB2TypeTests` class SHALL test the public properties and protocol conformances of `SMB2Client` that can be exercised without a live server connection.

#### Scenario: SMB2Client debugDescription is non-empty
- **WHEN** `debugDescription` is accessed on an SMB2Client instance
- **THEN** it SHALL return a non-empty string

#### Scenario: SMB2Client customMirror has children
- **WHEN** `customMirror` is accessed on an SMB2Client instance
- **THEN** it SHALL return a Mirror with at least one child

### Requirement: File monitoring type unit tests

`SMB2TypeTests` SHALL test `SMB2FileChangeType`, `SMB2FileChangeAction`, and `SMB2FileChangeInfo` public types.

#### Scenario: SMB2FileChangeType OptionSet operations
- **WHEN** SMB2FileChangeType values are combined with set operations (union, intersection)
- **THEN** the results SHALL follow OptionSet semantics

#### Scenario: SMB2FileChangeType description is non-empty
- **WHEN** `description` is accessed on an SMB2FileChangeType value
- **THEN** it SHALL return a non-empty string

#### Scenario: SMB2FileChangeAction equality and hashing
- **WHEN** two SMB2FileChangeAction values with the same rawValue are compared
- **THEN** they SHALL be equal and have the same hash value

#### Scenario: SMB2FileChangeAction description is non-empty
- **WHEN** `description` is accessed on an SMB2FileChangeAction value
- **THEN** it SHALL return a non-empty string

#### Scenario: SMB2FileChangeInfo equality
- **WHEN** two SMB2FileChangeInfo values with the same action and fileName are compared
- **THEN** they SHALL be equal

### Requirement: Build prerequisites documentation

CLAUDE.md SHALL document `git submodule update --init` as a required step before building.

#### Scenario: New developer follows build instructions
- **WHEN** a developer clones the repo and follows CLAUDE.md instructions
- **THEN** they SHALL be instructed to run `git submodule update --init` before `swift build`
