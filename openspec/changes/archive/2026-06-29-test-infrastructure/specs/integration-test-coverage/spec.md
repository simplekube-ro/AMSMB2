## ADDED Requirements

### Requirement: Append operation integration tests

`SMB2IntegrationTests` SHALL test the `append()` API to verify data is appended to existing files.

#### Scenario: Append data to existing file
- **WHEN** data is written to a file and then additional data is appended
- **THEN** reading the file SHALL return the original data followed by the appended data

### Requirement: removeItem integration tests

`SMB2IntegrationTests` SHALL test the generic `removeItem()` API that handles both files and directories.

#### Scenario: removeItem deletes a file
- **WHEN** `removeItem(atPath:)` is called on a file
- **THEN** the file SHALL be removed and subsequent access SHALL fail

#### Scenario: removeItem deletes a directory
- **WHEN** `removeItem(atPath:)` is called on a directory
- **THEN** the directory and its contents SHALL be removed

### Requirement: copyContentsOfItem integration tests

`SMB2IntegrationTests` SHALL test the `copyContentsOfItem()` API for server-side copy between paths.

#### Scenario: Copy file contents to new path
- **WHEN** `copyContentsOfItem(atPath:toPath:)` is called
- **THEN** the destination file SHALL contain the same data as the source

### Requirement: Echo integration test

`SMB2IntegrationTests` SHALL test the `echo()` API as a standalone connection liveness check.

#### Scenario: Echo succeeds on active connection
- **WHEN** `echo()` is called on an active SMB connection
- **THEN** the call SHALL complete without throwing

#### Scenario: Echo reflects connection state
- **WHEN** `echo()` is called after disconnecting
- **THEN** the call SHALL throw an error

### Requirement: Progress cancellation integration tests

`SMB2IntegrationTests` SHALL test that returning `false` from progress handlers cancels the operation.

#### Scenario: Write cancellation via progress handler
- **WHEN** a write operation's progress handler returns `false`
- **THEN** the write SHALL be cancelled and the operation SHALL throw an error or complete partially

#### Scenario: Read cancellation via progress handler
- **WHEN** a read operation's progress handler returns `false`
- **THEN** the read SHALL be cancelled and the operation SHALL throw an error or return partial data

### Requirement: Error handling integration tests

`SMB2IntegrationTests` SHALL test error paths for common failure scenarios.

#### Scenario: Read from non-existent path
- **WHEN** `contents(atPath:)` is called with a path that does not exist
- **THEN** the call SHALL throw a POSIXError

#### Scenario: Write to read-only location
- **WHEN** `write(data:toPath:)` is called on a path the user cannot write to
- **THEN** the call SHALL throw a POSIXError

#### Scenario: Connect with invalid credentials
- **WHEN** `connectShare()` is called with wrong username/password
- **THEN** the call SHALL throw an error indicating authentication failure

#### Scenario: Connect to non-existent share
- **WHEN** `connectShare(name:)` is called with a share name that does not exist
- **THEN** the call SHALL throw an error

### Requirement: smbClient accessor integration test

`SMB2IntegrationTests` SHALL test the public `smbClient` accessor on SMB2Manager.

#### Scenario: smbClient returns valid client after connection
- **WHEN** `smbClient` is accessed after a successful `connectShare()`
- **THEN** it SHALL return an SMB2Client instance without throwing

#### Scenario: smbClient throws when not connected
- **WHEN** `smbClient` is accessed before connecting
- **THEN** it SHALL throw an error indicating no active connection
