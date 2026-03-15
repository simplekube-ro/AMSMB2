## ADDED Requirements

### Requirement: Graceful disconnect waits for in-flight operations
The test suite SHALL verify that `disconnectShare(gracefully: true)` waits for an in-flight write operation to complete before tearing down the connection. After disconnect returns, a reconnect SHALL confirm the written file exists with the correct size.

#### Scenario: Graceful disconnect during large write
- **WHEN** a 4 MB write is started concurrently and `disconnectShare(gracefully: true)` is called immediately after
- **THEN** the disconnect call blocks until the write completes, and reconnecting shows the file exists with the expected size

### Requirement: Non-graceful disconnect fails in-flight operations
The test suite SHALL verify that `disconnectShare(gracefully: false)` causes an in-flight write operation to fail with an error.

#### Scenario: Non-graceful disconnect during large write
- **WHEN** a 4 MB write is started concurrently and `disconnectShare(gracefully: false)` is called immediately after
- **THEN** the write task throws an error

### Requirement: Operations fail with correct errors after disconnect
The test suite SHALL verify that `contents()`, `write()`, and `contentsOfDirectory()` all throw a `POSIXError` when called after the connection has been disconnected.

#### Scenario: Read after disconnect
- **WHEN** the connection is disconnected gracefully and `contents(atPath:)` is called
- **THEN** a `POSIXError` is thrown

#### Scenario: Write after disconnect
- **WHEN** the connection is disconnected gracefully and `write(data:toPath:)` is called
- **THEN** a `POSIXError` is thrown

#### Scenario: List directory after disconnect
- **WHEN** the connection is disconnected gracefully and `contentsOfDirectory(atPath:)` is called
- **THEN** a `POSIXError` is thrown

### Requirement: Reconnect after disconnect produces full round-trip data integrity
The test suite SHALL verify that after disconnecting and reconnecting, data written before disconnect can be read back with identical content, and `echo()` succeeds on the new connection.

#### Scenario: Write, disconnect, reconnect, read back
- **WHEN** data is written, the connection is disconnected gracefully, then reconnected
- **THEN** reading the file back returns identical data and `echo()` succeeds

### Requirement: Short operation timeout fires on large write
The test suite SHALL verify that setting `timeout` to 0.001 seconds and attempting a 4 MB write causes the operation to fail with `POSIXError(.ETIMEDOUT)`.

#### Scenario: Tiny timeout triggers ETIMEDOUT on large write
- **WHEN** `timeout` is set to 0.001 and a 4 MB write is attempted
- **THEN** the write throws `POSIXError(.ETIMEDOUT)`
