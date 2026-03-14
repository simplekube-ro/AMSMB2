## ADDED Requirements

### Requirement: Handle field is synchronized
The `SMB2FileHandle.handle` optional field SHALL be protected by an `NSLock` so that `close()` and `deinit` cannot race on read/write of the optional.

#### Scenario: Concurrent close and deinit do not double-close
- **WHEN** thread A calls `close()` and thread B triggers `deinit` concurrently
- **THEN** exactly one thread SHALL perform the C-level close operation, and the other SHALL observe `handle == nil` and skip the close

#### Scenario: close() sets handle to nil atomically
- **WHEN** `close()` is called
- **THEN** it SHALL acquire the handle lock, read and nil-out `handle` in a single critical section, then release the lock before calling the C `smb2_close`

#### Scenario: deinit checks handle under lock
- **WHEN** `deinit` is entered
- **THEN** it SHALL acquire the handle lock, read `handle`, set it to nil, then release the lock before calling `smb2_close_async`

### Requirement: Thread-safety documentation on public members
All public members of `SMB2FileHandle` SHALL include documentation noting that operations on a single `SMB2FileHandle` instance are serialized through the parent `SMB2Client`'s internal lock, and that the handle is invalidated by disconnection.

#### Scenario: Public init has thread-safety doc
- **WHEN** a developer reads the documentation for `init(forReadingAtPath:on:)`
- **THEN** the doc comment SHALL state that operations are serialized through the client's lock
