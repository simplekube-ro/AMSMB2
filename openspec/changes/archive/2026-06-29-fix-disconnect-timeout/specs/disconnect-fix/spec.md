## ADDED Requirements

### Requirement: disconnect() completes promptly
`SMB2Client.disconnect()` MUST complete without blocking for the operation timeout duration. The method SHALL send a best-effort disconnect PDU and tear down socket monitoring in a single atomic operation on the event loop queue.

#### Scenario: Disconnect completes within 2 seconds
- **WHEN** `disconnectShare()` is called on a connected client
- **THEN** the call returns within 2 seconds (not blocked by the 60s default timeout)

### Requirement: disconnect() sends best-effort disconnect PDU
`SMB2Client.disconnect()` MUST queue the SMB2 Tree Disconnect PDU and flush it once via `smb2_service(POLLOUT)` before stopping socket monitoring. This ensures the server receives notification of the session teardown.

#### Scenario: Disconnect PDU sent before socket teardown
- **WHEN** `disconnect()` executes on a connected client
- **THEN** the disconnect PDU is queued and flushed before `stopSocketMonitoring()` is called

### Requirement: disconnect() fails all pending operations
After sending the disconnect PDU, `disconnect()` MUST fail all pending in-flight operations with `POSIXError(.ENOTCONN)` so that waiting callers unblock immediately.

#### Scenario: Pending operations receive ENOTCONN after disconnect
- **WHEN** operations are in-flight and `disconnect()` is called
- **THEN** all pending operations receive an `ENOTCONN` error
