## ADDED Requirements

### Requirement: smbClient getter acquires connectLock
The `SMB2Manager.smbClient` computed property SHALL acquire `connectLock` before reading `self.client`, preventing a TOCTOU race with `connectShare`/`disconnectShare`.

#### Scenario: Concurrent disconnect does not return stale client
- **WHEN** thread A calls `smbClient` and thread B calls `disconnectShare` concurrently
- **THEN** thread A SHALL either return the client before disconnect begins, or throw `ENOTCONN` after disconnect completes — never return a reference to a client that is being or has been disconnected

### Requirement: smbClient validates connection state
The `smbClient` getter SHALL check both that `client` is non-nil AND that `client.fileDescriptor != -1` (indicating the context is alive), throwing `POSIXError(.ENOTCONN)` if either check fails.

#### Scenario: Client exists but context destroyed
- **WHEN** `smbClient` is called after `service(revents:)` has destroyed the context (setting `context = nil`) but before `SMB2Manager` has set `self.client = nil`
- **THEN** the getter SHALL throw `POSIXError(.ENOTCONN)` because `fileDescriptor == -1`

#### Scenario: Client is nil
- **WHEN** `smbClient` is called before `connectShare` has been called
- **THEN** the getter SHALL throw `POSIXError(.ENOTCONN)`

#### Scenario: Client is connected and healthy
- **WHEN** `smbClient` is called while a connection is active
- **THEN** the getter SHALL return the `SMB2Client` instance
