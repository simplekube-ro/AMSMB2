# disconnect-fix Specification

## Purpose
Fix the `SMB2Client.disconnect()` sequencing bug that caused every disconnect to block for the full operation timeout (default 60s). Socket monitoring was being stopped before the disconnect PDU was sent, leaving the `async_await` round-trip waiting on a `DispatchSource` that was already nil — so it only returned after `ETIMEDOUT`. The fix adopts the fire-and-forget pattern used by `shutdown()`: queue a best-effort disconnect PDU, flush it once via `smb2_service(POLLOUT)`, then tear down socket monitoring and fail pending operations — all atomically on the event loop queue. The public API (`disconnectShare`) is unchanged.

## Requirements
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

### Requirement: disconnect() reclaims the SMB2 context and every pending callback object
After failing all pending operations, `SMB2Client.disconnect()` MUST destroy the underlying SMB2
context on the event loop queue, in the same sequence `deinit` teardown uses, so that every
callback object still registered with libsmb2 is released before `disconnect()` returns rather
than deferred to the client's deallocation. Pending operations MUST be marked abandoned before the
context is destroyed so that the destroy-fired callbacks do not resume an already-resumed caller.

#### Scenario: Operation pending against a non-replying peer at disconnect
- **WHEN** `disconnect()` is called while at least one operation has been queued to libsmb2 and
  no reply has arrived
- **THEN** the waiting caller receives `POSIXError(.ENOTCONN)`, the client holds no SMB2
  context, and by the time `disconnect()` returns libsmb2 has released its retain on every
  pending callback object, so the live callback-object count returns to its pre-operation
  baseline once the waiting caller's frame has released its own reference (the per-operation
  timeout timer captures the callback object weakly and does not extend its lifetime)

#### Scenario: Client is released after disconnect
- **WHEN** the last strong reference to a client is dropped after `disconnect()` returned
- **THEN** the client deallocates immediately (no pending operation keeps it alive) and no second
  context destroy is attempted

#### Scenario: External transport handle is released at disconnect
- **WHEN** `disconnect()` is called on a client connected through the transport seam
- **THEN** the retain the external-transport registration handed to libsmb2 is balanced before
  `disconnect()` returns, so a weak reference to the transport bridge is nil afterwards rather
  than surviving until the client deallocates

#### Scenario: Transport failure already destroyed the context
- **WHEN** `disconnect()` is called after a servicing error has already destroyed the context
- **THEN** `disconnect()` completes without error and without attempting a second destroy

### Requirement: disconnect() is terminal for the client instance
A client on which `disconnect()` has returned MUST NOT be reconnected; callers obtain a fresh
client to reconnect. Any operation issued through such a client — including through a file or
directory handle opened before the disconnect — MUST fail immediately with
`POSIXError(.ENOTCONN)`, not after the operation timeout. This contract MUST be stated in the
documentation of `disconnect()`.

#### Scenario: Operation on a stale handle after disconnect fails fast
- **WHEN** a read, write, or other operation is issued on a handle whose client has been
  disconnected
- **THEN** it throws `POSIXError(.ENOTCONN)` well before the client's operation timeout would
  elapse

#### Scenario: Manager reconnect after disconnect uses a fresh client
- **WHEN** `SMB2Manager.connectShare` is called after `disconnectShare`
- **THEN** the connection is established on a newly constructed client and subsequent operations
  succeed

#### Scenario: Repeated disconnect is harmless
- **WHEN** `disconnect()` is called a second time on the same client
- **THEN** it returns promptly without error
